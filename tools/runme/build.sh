# Copyright (C) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See LICENSE in project root for information.

################################################################################
# Build

# Since developers usually work in the IDE, most of the build mechanics is done
# by SBT.

_show_template_line() {
  eval show - "$(qstr -not-dollar "${2%$'\n'}")"
}

_generate_description() {
  if [[ "$BUILDMODE" != "server" || "$AGENT_ID" = "" ]]; then return; fi
  show section "Generating Build.md"
  show command "... > $(qstr "$BUILD_ARTIFACTS/Build.md")"
  mapfile -c 1 -C _show_template_line \
    < "$RUNMEDIR/build-readme.tmpl" > "$BUILD_ARTIFACTS/Build.md"
  if [[ "$PUBLISH" = "all" ]]; then
    printf '\nThis is a **publishing** build.\n' >> "$BUILD_ARTIFACTS/Build.md"
    echo "##vso[build.addbuildtag]Publish"
  fi
  # upload the generated description lazily on exit, so we can add info lines below
  echo_exit "##vso[task.uploadsummary]$BUILD_ARTIFACTS/Build.md"
}
_add_to_description() { # -f file | fmt arg...
  { echo ""
    if [[ "x$1" = "x-f" ]]; then if [[ -r "$2" ]]; then cat "$2"; fi
    else printf "$@"; fi
  } >> "$BUILD_ARTIFACTS/Build.md"
}

_postprocess_sbt_log() {
  # Adapts the SBT output to work nicely with the VSTS build, most of the work
  # is for the SPARK output logs
  local line rx tag text oIFS="$IFS"
  IFS="" # preserve whitespaces
  # Prefix finding regexp
  rx=$'^(\e[[0-9]+m)?\[?(\e[[0-9]+m)??'
  rx+=$'(warning|WARNING|warn|WARN|info|INFO|error|ERROR)'
  rx+=$'(\e[[0-9]+m)?\]?(\e[[0-9]+m)? *(.*)'
  while read -r line || [[ -n "$line" ]]; do
    # Drop time stamps from SPARK output lines
    line="${line#[0-9][0-9]/[0-9][0-9]/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] }"
    # Highlight a prefix of "[warning]" with optional brackets, and the same
    # for "warn"s, "error"s and "info"s (for info, just drop the prefix); do
    # that for uppercase also, but *not* mixed since spark shows a line that
    # starts with "Info provided"
    if [[ "${line}" =~ $rx ]]; then
      tag="${BASH_REMATCH[3],,}"
      if [[ "$tag" = "warn" ]]; then tag="warning"
      elif [[ "$tag" = "info" ]]; then tag="-"
      fi
      # preserve the line (with escape sequences) when in interactive mode
      if [[ "${BUILDMODE}${BASH_REMATCH[1]}" != "server" ]]; then text="$line"
      else text="${BASH_REMATCH[6]}"
      fi
      show "$tag" "$text"
    else
      echo "$line"
    fi
  done
  IFS="$oIFS"
}

_prepare_build_artifacts() {
  show section "Preparing Build"
  _rm "$BUILD_ARTIFACTS" "$TEST_RESULTS"
  _ mkdir -p "$BUILD_ARTIFACTS/sdk" "$TEST_RESULTS"
  _ cp -a "$BASEDIR/LICENSE" "$BUILD_ARTIFACTS"
  _ cp -a "$BASEDIR/LICENSE" "$BUILD_ARTIFACTS/sdk"
  echo "$MML_VERSION" > "$BUILD_ARTIFACTS/version"
  local paths
  # copy only the test notebooks from notebooks/tests to the local test
  # directory -- running all notebooks is covered better by the E2E tests
  for paths in "samples:$BUILD_ARTIFACTS/notebooks" "tests:$TEST_RESULTS/notebook_tests"; do
    _ "$BASEDIR/tools/notebook/postprocess.py" "$BASEDIR/notebooks/${paths%%:*}" "${paths#*:}"
  done
}

_sbt_run() { # sbt-args...
  local flags=""; if [[ "$BUILDMODE" = "server" ]]; then flags="-no-colors"; fi
  (set -o pipefail; _ sbt $flags "$@" < /dev/null 2>&1 | _postprocess_sbt_log) \
    || exit $?
}

_sbt_build() {
  show section "Running SBT Build"
  local owd="$PWD" restore_opt="$(shopt -p nullglob)"; shopt -s nullglob
  cd "$SRCDIR"
  local rmjars=( **/"target/scala-"*/!(*"-$MML_VERSION")".jar" )
  $restore_opt
  if [[ "${#rmjars[@]}" != "0" ]]; then
    show command "rm **/target/...stale-jars"
    __ rm "${rmjars[@]}"
  fi
  local TESTS="$TESTS"
  if ! should test scala; then TESTS="none"
  else # Hide the "+scala" tag
    TESTS=",$TESTS,"; TESTS="${TESTS//,+scala,/,}"; TESTS="${TESTS#,}"; TESTS="${TESTS%,}"
    if [[ "$TESTS" = "" ]]; then TESTS="all"; fi
  fi
  _sbt_run "full-build"
  # leave only the -assembley jars under the proper name (and the pom files)
  local f; for f in "$BUILD_ARTIFACTS/packages/m2/"**; do case "$f" in
    ( *-@(javadoc|sources).jar@(|.md5|.sha1) ) _rm "$f" ;;
    ( *-assembly.jar@(|.md5|.sha1) ) _ mv "$f" "${f//-assembly.jar/.jar}" ;;
  esac; done
  cd "$owd"
}

_upload_to_storage() { # name, pkgdir, container
  show section "Publishing $1 Package"
  _ az storage blob upload-batch --account-name "$MAIN_CONTAINER" \
       --source "$BUILD_ARTIFACTS/packages/$2" --destination "$3"
}

_e2e_script_action() { # script-name file-name config-name
  local cnf="$1" script_name="$2" file="$3"; shift 3
  local cluster="${cnf}_CLUSTER_NAME" group="${cnf}_RESOURCE_GROUP"
  local url="$STORAGE_URL/$MML_VERSION/$file"
  collect_log=1 \
    _ azure hdinsight script-action create "${!cluster}" -g "${!group}" \
            -n "$script_name" -u "$url" -t "headnode;workernode"
  echo "$collected_log"
  if [[ ! "$collected_log" =~ "Operation state: "+"Succeeded" ]]; then
    failwith "script action failed"
  fi
}
e2ekey=""
_e2e_ssh() {
  local cmd keyfile rm_pid ret
  cmd=("ssh"); if [[ "$1" = "scp" ]]; then cmd=("$1"); shift; fi
  if [[ "$_e2e_key" = "" ]]; then
    e2ekey="$(__ az keyvault secret show --vault-name mmlspark-keys --name testcluster-ssh-key)"
    e2ekey="${e2ekey##*\"value\": \"}"; e2ekey="${e2ekey%%\"*}"; e2ekey="${e2ekey//\\n/$'\n'}"
  fi
  keyfile="/dev/shm/k$$"; touch "$keyfile"; chmod 600 "$keyfile"; echo "$e2ekey" > "$keyfile"
  cmd+=(-o "StrictHostKeyChecking=no" -i "$keyfile")
  if [[ "${cmd[0]}" = "ssh" ]]; then
    { sleep 30; rm -f "$keyfile"; } &
    rm_pid="$!"
    _ -a "${cmd[@]}" "$@"; ret="$?"
    kill -9 "$rm_pid" > /dev/null 2>&1; rm -f "$keyfile"
  elif [[ "${cmd[0]}" = "scp" ]]; then
    _ -a "${cmd[@]}" "$@"; ret="$?"
    rm -f "$keyfile"
  fi
  return $ret
}
_e2e_tests() {
  show section "Running E2E Tests"
  _e2e_script_action "E2E" "Install MML to E2E Cluster" "install-mmlspark.sh"
  _e2e_script_action "E2E" "Setup authorized-keys for E2E" "setup-test-authkey.sh"
  local shost="$E2E_CLUSTER_SSH" sdir="$CLUSTER_SDK_DIR/notebooks/hdinsight"
  _e2e_ssh scp -p "$TEST_RESULTS/notebook_tests/hdinsight/"* "$shost:$sdir"
  _e2e_ssh scp -p "$BASEDIR/tools/notebook/tester/"* "$shost:$sdir"
  _e2e_ssh -t -t "$shost" \
           ". /usr/bin/anaconda/bin/activate; \
            cd \"$sdir\"; rm -rf \"../local\"; \
            ./parallel_run.sh 2 \"TestNotebooksOnHdi.py\""
  local ret="$?"
  _e2e_ssh scp "$shost:$sdir/TestResults/*" "$TEST_RESULTS"
  if ((ret != 0)); then failwith "E2E test failures"; fi
}

_publish_to_demo_cluster() {
  show section "Installing Demo Cluster"
  _e2e_script_action "DEMO" "Install MML to Demo Cluster" "install-mmlspark.sh"
}

_publish_to_dockerhub() {
  @ "../docker/build-docker"
  local itag="mmlspark:latest" otag otags
  otag="microsoft/mmlspark:$MML_VERSION"; otag="${otag//+/_}"; otags=("$otag")
  if [[ "$MML_VERSION" = *([0-9.]) ]]; then otags+=( "microsoft/mmlspark:latest" ); fi
  show section "Pushing to Dockerhub as ${otags[*]}"
  show - "Image info:"
  local info="$(docker images "$itag")"
  if [[ "$info" != *$'\n'* ]]; then failwith "tag not found: $itag"; fi
  info="  | ${info//$'\n'/$'\n  | '}"
  echo "$info"
  local auth user pswd
  __ docker logout > /dev/null
  auth="$(__ az keyvault secret show --vault-name mmlspark-keys --name dockerhub-auth)"
  auth="${auth##*\"value\": \"}"; auth="${auth%%\"*}"; auth="$(base64 -d <<<"$auth")"
  user="${auth%%:*}" pswd="${auth#*:}"
  ___ docker login -u "$user" -p "$pswd" > /dev/null
  unset user pass auth
  for otag in "${otags[@]}"; do
    show - "Pushing \"$otag\""
    _ docker tag "$itag" "$otag"
    _ docker push "$otag"
    _ docker rmi "$otag"
  done
  __ docker logout > /dev/null
}

_upload_artifacts_to_VSTS() {
  if [[ "$BUILDMODE" != "server" ]]; then return; fi
  show section "Uploading Build Artifacts to VSTS"
  local f d
  for f in "$BUILD_ARTIFACTS/"**/*; do
    if [[ -d "$f" ]]; then continue; fi
    f="${f#$BUILD_ARTIFACTS}"; d="${f%/*}"
    echo "##vso[artifact.upload artifactname=Build$d]$BUILD_ARTIFACTS/$f"
  done
}

_upload_artifacts_to_storage() {
  show section "Uploading Build Artifacts to Storage"
  _ az account show > /dev/null # this fails if not logged-in
  local tmp="/tmp/mmlbuild-$$" # temporary place for uploads
  mkdir -p "$tmp"
  ( cd "$BUILD_ARTIFACTS"
    _ zip -qr9 "$tmp/$(basename "$BUILD_ARTIFACTS.zip")" * )
  local f txt
  for f in "$TOOLSDIR/hdi/"*; do
    txt="$(< "$f")"
    txt="${txt//<=<=fill-in-maven-package=>=>/com.microsoft.ml.spark:mmlspark_$SCALA_VERSION:$MML_VERSION}"
    txt="${txt//<=<=fill-in-maven-url=>=>/$MAVEN_URL}"
    txt="${txt//<=<=fill-in-pip-package=>=>/$PIP_URL/$PIP_PACKAGE}"
    txt="${txt//<=<=fill-in-sdk-dir=>=>/$CLUSTER_SDK_DIR}"
    txt="${txt//<=<=fill-in-url=>=>/$STORAGE_URL/$MML_VERSION}"
    echo "$txt" > "$tmp/$(basename "$f")"
  done
  _ az storage blob upload-batch --account-name "$MAIN_CONTAINER" \
       --source "$tmp" --destination "$STORAGE_CONTAINER/$MML_VERSION"
  _rm "$tmp"
  _add_to_description \
    'Copy the link to [%s](%s) to setup this build on a cluster.' \
    "this HDInsight Script Action" "$STORAGE_URL/$MML_VERSION/install-mmlspark.sh"
}

_full_build() {
  show section "Building ($MML_VERSION)"
  _ cd "$BASEDIR"
  _prepare_build_artifacts
  _generate_description
  _sbt_build
  _ ln -sf "$(realpath --relative-to="$HOME/bin" "$TOOLSDIR/bin/mml-exec")" \
           "$HOME/bin"
  should publish maven   && _upload_to_storage "Maven" "m2" "$MAVEN_CONTAINER"
  should test python     && @ "../pytests/auto-tests"
  should test python     && @ "../pytests/notebook-tests"
  should publish pip     && @ "../pip/generate-pip.sh"
  should publish pip     && _upload_to_storage "PIP" "pip" "$PIP_CONTAINER"
  should publish storage && _upload_artifacts_to_storage
  should test e2e        && _e2e_tests
  should publish demo    && _publish_to_demo_cluster
  should publish docker  && _publish_to_dockerhub
  if [[ -n "$BUILD_INFO_EXTRA_MARKDOWN" ]]; then
    _add_to_description -f "$BUILD_INFO_EXTRA_MARKDOWN"
  fi
  _upload_artifacts_to_VSTS
  return 0
}
