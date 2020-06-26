#!/usr/bin/env bash

# Running in df core check
[[ -z "$DF_PLUGIN" ]] && return

# Get our current directory
DEAFULT_PACKAGES_PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Some default variables
DEFAULT_PACKAGES_DIR=${DEFAULT_PACKAGES_DIR:-"$HOME/.default-packages"}
DEFAULT_PACKAGES_INFO_FILE=${DEFAULT_PACKAGES_INFO_FILE:-"info.json"}
PACKAGES_FILE_NAME=${PACKAGES_FILE_NAME:-"packages.json"}
PACKAGE_SOURCE_FILE_PREFIX=${PACKAGE_SOURCE_FILE_PREFIX:-"packages"}

dotfile_plugin_default_packages_plugin_init() {

    # Add our hooks
    hook init dotfile_plugin_default_packages_init
    hook cleanup dotfile_plugin_default_packages_cleanup
    hook install_start dotfile_plugin_default_packages_install_prerequisites
    hook install_start dotfile_plugin_default_packages_clear_existing
    hook topic_exec dotfile_plugin_default_packages_run
}

dotfile_plugin_default_packages_init() {

    # Create the default packages directory that we need
    [[ ! -d $DEFAULT_PACKAGES_DIR ]] && mkdir -p $DEFAULT_PACKAGES_DIR

    # Create a temporary file for logging which files have been processed
    PACKAGE_PROCESSED_TOPIC_LIST=$(mktemp -t df-plugin-default-packages-processed.XXXXXXXX)

}

dotfile_plugin_default_packages_cleanup() {

    # Delete our temporary files
    [[ -f $PACKAGE_PROCESSED_TOPIC_LIST ]] && rm $PACKAGE_PROCESSED_TOPIC_LIST
}

dotfile_plugin_default_packages_install_prerequisites() {

    # These should already be installed but try and install some packages
    packages restrict brew | packages install coreutils
    packages install jq
}

dotfile_plugin_default_packages_clear_existing() {
    local PACKAGE_INFO=$DEFAULT_PACKAGES_DIR/$DEFAULT_PACKAGES_INFO_FILE

    local PACKAGE_GROUPS
    local PACKAGE_FILES
    local SOURCE_FILE
    local TARGET_FILE

    local JQ_EXPRESSION

    # If the info file doesn't exist, skip
    [[ ! -f $PACKAGE_INFO ]] && return 0

    # Read in each group from the file
    PACKAGE_GROUPS=$(jq -r 'keys[]' $PACKAGE_INFO)

    # Loop through each type, removing each source file and linked file
    for PACKAGE_GROUP in ${PACKAGE_GROUPS[*]}; do
        JQ_EXPRESSION=".$PACKAGE_GROUP[] | (.source + \":\" + .target)"
        PACKAGE_FILES=$(jq -r "$JQ_EXPRESSION" $PACKAGE_INFO)

        # Loop through each file specified in the file
        for PACKAGE_FILE in ${PACKAGE_FILES[*]}; do

            # Split the source and target files
            SOURCE_FILE=$(echo $PACKAGE_FILE | cut -f 1 -d :)
            TARGET_FILE=$(echo $PACKAGE_FILE | cut -f 2 -d :)

            # Delete the files
            [[ -f $TARGET_FILE ]] && rm $TARGET_FILE
            [[ -f $SOURCE_FILE ]] && rm $SOURCE_FILE
        done
    done

    # Delete the info file
    rm $PACKAGE_INFO
}

dotfile_plugin_default_packages_run() {
    local ROOT_DIR=$1
    local FILE=$2
    local TOPIC=$3
    local DIR=$4
    local SCRIPT_FILE=$5

    local FILE_TYPE
    local FILE_SOURCE
    local FILE_TARGET
    local FILE_TARGET_TEST
    local FILE_PACKAGE_LIST
    local FILE_SOURCE_NAME

    # Remove extension from passed files
    FILE=${FILE%.*}
    SCRIPT_FILE=${SCRIPT_FILE%.*}

    # If there is no packages.json in the topic directory, exit
    [[ ! -f $DIR/$PACKAGES_FILE_NAME ]] && return

    # If the file exists, check if we have already processed this particular topic
    local TOPIC_PROCESS_LINE="$ROOT_DIR:$DIR:$TOPIC"
    cat $PACKAGE_PROCESSED_TOPIC_LIST | grep $QUIET_FLAG_GREP "$TOPIC_PROCESS_LINE" 2>/dev/null && return

    # Read the file and pull in the necessary info
    FILE_TYPE=$(jq -r '.type // empty' $DIR/$PACKAGES_FILE_NAME)
    FILE_TARGET=$(jq -r '.file // empty' $DIR/$PACKAGES_FILE_NAME)
    FILE_TARGET_TEST=$(jq -r '.testdir // empty' $DIR/$PACKAGES_FILE_NAME)
    FILE_PACKAGE_LIST=$(jq -r '.packages[]' $DIR/$PACKAGES_FILE_NAME)

    # If the type is blank, skip this
    [[ -z $FILE_TYPE ]] && return 0

    # If filename is blank, use the file type instead
    if [[ -z $FILE_TARGET ]] || [[ "$FILE_TARGET" == "null" ]]; then
        FILE_TARGET=$(dotfile_plugin_default_packages_get_file_target $FILE_TYPE)
    fi

    # If the file test target is blank, use the directory of the file target
    if [[ -z $FILE_TARGET_TEST ]] || [[ "$FILE_TARGET_TEST" == "null" ]]; then
        FILE_TARGET_TEST=$(dirname $FILE_TARGET)
    fi

    # If the target directory doesn't exist, don't do anything
    [[ -d $FILE_TARGET_TEST ]] || return 0

    # Get the source file for this file
    FILE_SOURCE_NAME=$(dotfile_plugin_default_packages_get_source_file_name $FILE_TARGET)
    FILE_SOURCE=$DEFAULT_PACKAGES_DIR/$FILE_SOURCE_NAME

    # If the package file doesn't exist, create it and log it in the info file
    [[ ! -f $FILE_SOURCE ]] && dotfile_plugin_default_packages_create_file $FILE_TYPE $FILE_SOURCE $FILE_TARGET

    # Link the files
    dotfile_plugin_default_packages_link_file $FILE_SOURCE $FILE_TARGET

    # Write the list of packages to the file
    for PACKAGE in ${FILE_PACKAGE_LIST[@]}; do
        echo $PACKAGE >> $FILE_SOURCE
    done

    # Deduplicate entries in the file
    dotfile_plugin_default_packages_remove_duplicates $FILE_SOURCE

    # Mark the topic as processed at this point
    echo "$TOPIC_PROCESS_LINE" >> $PACKAGE_PROCESSED_TOPIC_LIST
}

dotfile_plugin_default_packages_create_file() {
    local FILE_TYPE=$1
    local SOURCE_FILE=$2
    local TARGET_FILE=$3

    local JQ_EXPRESSION
    local PACKAGE_INFO=$DEFAULT_PACKAGES_DIR/$DEFAULT_PACKAGES_INFO_FILE

    # Temporary file because you can't inline edit json files with jq
    local TMP_JSON_FILE=$(mktemp -t df-plugin-default-packages-info-file.XXXXXXXX)

    # If the info file doesn't exist, create it
    [[ ! -f $PACKAGE_INFO ]] && echo "{}" > $PACKAGE_INFO

    # Create the source file
    touch $SOURCE_FILE

    # Check if the key already exists
    JQ_EXPRESSION=".$FILE_TYPE | type"
    if [[ ! "$(jq -r "$JQ_EXPRESSION" $PACKAGE_INFO)" == "array" ]]; then

        # Add the key to the file
        JQ_EXPRESSION=". + {\"$FILE_TYPE\": []}"
        jq "$JQ_EXPRESSION" $PACKAGE_INFO > $TMP_JSON_FILE
        cp $TMP_JSON_FILE $PACKAGE_INFO
    fi

    # Add the file to the info file
    JQ_EXPRESSION=".$FILE_TYPE += [{\"source\": \"$SOURCE_FILE\", \"target\": \"$TARGET_FILE\"}]"
    jq "$JQ_EXPRESSION" $PACKAGE_INFO > $TMP_JSON_FILE
    cp $TMP_JSON_FILE $PACKAGE_INFO

    # Remove our temporary file
    rm $TMP_JSON_FILE
}

dotfile_plugin_default_packages_link_file() {
    local SOURCE_FILE=$1
    local TARGET_FILE=$2

    # Backup any existing default packages file if it is an actual file and not a link
    [[ -f $TARGET_FILE ]] && mv $TARGET_FILE $TARGET_FILE.bak

    # If the file is a link, test if it matches our source file
    if [[ -L $TARGET_FILE ]]; then

        # Test if the link target is our source file
        [[ "$(resolve_symlink -f -n $TARGET_FILE)" == "$SOURCE_FILE" ]] && return 0

        # Move the link to a backup
        mv $TARGET_FILE $TARGET_FILE.bak
    fi

    # Link the source file to the target location
    ln -s $SOURCE_FILE $TARGET_FILE
}

dotfile_plugin_default_packages_remove_duplicates() {
    local FILE=$1

    # Temporary file because you can't inline edit files
    local TMP_FILE=$(mktemp -t df-plugin-default-packages-package-file.XXXXXXXX)

    # Run the package file through sort and uniq and then overwrite the existing file
    sort $FILE | uniq > $TMP_FILE
    cp $TMP_FILE $FILE

    # Remove the temporary file
    rm $TMP_FILE
}

dotfile_plugin_default_packages_get_file_target() {
    local FILE_TYPE=$1
    local FILE_PATH
    local KEY_EXISTS

    local JQ_EXPRESSION

    # Try and get the type from our local file
    JQ_EXPRESSION=".$FILE_TYPE | type"
    [[ "$(jq -r "$JQ_EXPRESSION" $DEAFULT_PACKAGES_PLUGIN_DIR/files.json)" == "string" ]] && {
        JQ_EXPRESSION=".$FILE_TYPE"
        FILE_PATH=$(jq -r "$JQ_EXPRESSION" $DEAFULT_PACKAGES_PLUGIN_DIR/files.json)
    }

    # If we have a target, run expansion on it
    FILE_PATH=$(echo $FILE_PATH | tr ' ' '-')
    [[ "$FILE_PATH" =~ .*'$'.* ]] && FILE_PATH=$(eval echo $FILE_PATH)

    # Return the value
    echo $FILE_PATH
    return 0
}

dotfile_plugin_default_packages_get_source_file_name() {
    local TARGET_FILE=$1
    local SOURCE_FILE

    # Convert all special characters to underscores
    SOURCE_FILE=$(echo $TARGET_FILE | tr '.:\/-' '_')

    # Add the prefix to the string
    SOURCE_FILE=$(echo $PACKAGE_SOURCE_FILE_PREFIX$SOURCE_FILE)

    # Return the value
    echo $SOURCE_FILE
    return 0
}

hook plugin_init dotfile_plugin_default_packages_plugin_init
