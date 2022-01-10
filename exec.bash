#!/bin/bash

#allow local connections of root (docker daemon) to the current users x server
if command -v xhost > /dev/null; then
    xhost +local:root > /dev/null
fi

ROOT_DIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $ROOT_DIR/docker_commands.bash

CONTAINER_USER=devel
CMD_STRING=""

### EVALUATE ARGUMENTS AND SET EXECMODE
EXECMODE=$DEFAULT_EXECMODE
if [ "$1" = "base" ]; then
    $PRINT_WARNING "overriding default execmode $DEFAULT_EXECMODE to: base"
    EXECMODE="base"
    shift
fi
if [ "$1" = "devel" ]; then
    $PRINT_WARNING "overriding default execmode $DEFAULT_EXECMODE to: devel"
    EXECMODE="devel"
    shift
fi
if [ "$1" = "release" ]; then
    $PRINT_WARNING "overriding default execmode $DEFAULT_EXECMODE to: release"
    EXECMODE="release"
    shift
fi
if [ "$1" = "storedrelease" ]; then
    $PRINT_WARNING "overriding default execmode $DEFAULT_EXECMODE to: storedrelease"
    EXECMODE="storedrelease"
    shift
fi
if [ "$1" = "CD" ]; then
    $PRINT_WARNING "overriding default execmode $DEFAULT_EXECMODE to: CD"
    EXECMODE="CD"
    shift
fi

### EVALUATE REMAINING ARGUMENTS OR SET TO DEFAULT
if [ -z "$1" ]; then
    CMD_STRING="No run argument given. Executing: /bin/bash"
    set -- "/bin/bash"
elif [ "$1" = "write_osdeps" ]; then
    CMD_STRING="Executing: /opt/write_osdeps.bash"
    set -- "/opt/write_osdeps.bash"
else 
    CMD_STRING="Executing: $1"
fi

### START EXECUTION
if [ "$EXECMODE" == "base" ]; then
    # DOCKER_REGISTRY and WORKSPACE_DEVEL_IMAGE from settings.bash
    IMAGE_NAME=${BASE_REGISTRY:+${BASE_REGISTRY}/}$WORKSPACE_BASE_IMAGE
    mkdir -p $ROOT_DIR/workspace
    mkdir -p $ROOT_DIR/home
    ADDITIONAL_DOCKER_MOUNT_ARGS=" \
        -v $ROOT_DIR/workspace/:/opt/workspace \
        -v $ROOT_DIR/home/:/home/devel \
        -v $ROOT_DIR/image_setup/02_devel_image/setup_workspace.bash:/opt/setup_workspace.bash \
        -v $ROOT_DIR/image_setup/02_devel_image/workspace_os_dependencies.txt:/opt/workspace_os_dependencies.txt \
        -v $ROOT_DIR/image_setup/02_devel_image/list_rock_osdeps.rb:/opt/list_rock_osdeps.rb \
        -v $ROOT_DIR/image_setup/02_devel_image/list_ros_osdeps.bash:/opt/list_ros_osdeps.bash \
        -v $ROOT_DIR/image_setup/02_devel_image/write_osdeps.bash:/opt/write_osdeps.bash \
        "
fi

if [ "$EXECMODE" = "devel" ]; then
    # DOCKER_REGISTRY and WORKSPACE_DEVEL_IMAGE from settings.bash
    IMAGE_NAME=${DEVEL_REGISTRY:+${DEVEL_REGISTRY}/}$WORKSPACE_DEVEL_IMAGE
    #in case the devel image is pulled, we need the create the folders here
    mkdir -p $ROOT_DIR/workspace
    mkdir -p $ROOT_DIR/home
    ADDITIONAL_DOCKER_MOUNT_ARGS=" \
        -v $ROOT_DIR/startscripts:/opt/startscripts \
        -v $ROOT_DIR/workspace/:/opt/workspace \
        -v $ROOT_DIR/home/:/home/devel \
        -v $ROOT_DIR/image_setup/02_devel_image/workspace_os_dependencies.txt:/opt/workspace_os_dependencies.txt \
        -v $ROOT_DIR/image_setup/02_devel_image/list_rock_osdeps.rb:/opt/list_rock_osdeps.rb \
        -v $ROOT_DIR/image_setup/02_devel_image/list_ros_osdeps.bash:/opt/list_ros_osdeps.bash \
        -v $ROOT_DIR/image_setup/02_devel_image/write_osdeps.bash:/opt/write_osdeps.bash \
        "
    if [ "$MOUNT_CCACHE_VOLUME" = "true" ]; then
        DOCKER_DEV_CCACHE_DIR="/ccache"
        CACHE_VOMUME_NAME="ccache_${WORKSPACE_BASE_IMAGE//[\/,:]/_}"
        $PRINT_INFO "mounting ccache volume ${CACHE_VOMUME_NAME} to ${DOCKER_DEV_CCACHE_DIR}"
        docker volume create $CACHE_VOMUME_NAME > /dev/null
        ADDITIONAL_DOCKER_MOUNT_ARGS="$ADDITIONAL_DOCKER_MOUNT_ARGS -v $CACHE_VOMUME_NAME:${DOCKER_DEV_CCACHE_DIR}"
    fi
fi

# needs to be executed before execmode == release is evaluated!
if [ "$EXECMODE" = "CD" ]; then
    WORKSPACE_RELEASE_IMAGE=$WORKSPACE_CD_IMAGE
    DOCKER_REGISTRY_AUTOPULL=true
    EXECMODE="release"
fi

if [ "$EXECMODE" = "release" ]; then
    # DOCKER_REGISTRY and WORKSPACE_DEVEL_IMAGE from settings.bash
    IMAGE_NAME=${RELEASE_REGISTRY:+${RELEASE_REGISTRY}/}$WORKSPACE_RELEASE_IMAGE
    CONTAINER_USER=release
fi

if [ "$EXECMODE" = "storedrelease" ]; then
    # Read image name from command line, first arg already shifted away
    STORED_IMAGE_NAME=$1
    if [ ! -f .stored_images.txt ]; then
            $PRINT_WARNING "there are no stored images available (file missing: .stored_images.txt)."
        exit 1
    fi
    if [ -z "$STORED_IMAGE_NAME" ]; then
        $PRINT_WARNING
        $PRINT_WARNING "please provide the name tag for the stored release you wish to use."
        print_stored_image_tags
        exit 1
    fi
    IMAGE_NAME=$(cat .stored_images.txt | grep "^$STORED_IMAGE_NAME=" | awk -F'=' '{print $2}')
    if [ -z "$IMAGE_NAME" ]; then
        $PRINT_WARNING
        $PRINT_WARNING "unknown image name: $STORED_IMAGE_NAME"
        print_stored_image_tags
        exit 1
    fi
    CONTAINER_USER=release
    shift
fi

if [ "$DOCKER_REGISTRY_AUTOPULL" = true ]; then
    $PRINT_INFO
    $PRINT_INFO pulling image: $IMAGE_NAME
    $PRINT_INFO
    docker pull $IMAGE_NAME
fi

# this flag defines if an interactive container (console inputs) is created or not
# if env already set, use external set value
# you can use this if your console does not support inputs (e.g. a jenkins build job)
INTERACTIVE=${INTERACTIVE:="true"}

# get a md5 for the current folder used as container name suffix
# (several checkouts  of this repo possible without interfering)
FOLDER_MD5=$(echo $ROOT_DIR | md5sum | cut -b 1-8)

# use current folder name + devel + path md5 as container name
# (several checkouts  of this repo possible withtout interfering)
CONTAINER_NAME=${CONTAINER_NAME:="${ROOT_DIR##*/}-$EXECMODE-$FOLDER_MD5"}

$PRINT_INFO
$PRINT_INFO -e "\e[32musing ${IMAGE_NAME%:*}:\e[4;33m${IMAGE_NAME##*:}\e[0m"
$PRINT_INFO
$PRINT_DEBUG $CMD_STRING
$PRINT_DEBUG

CONTAINER_IMAGE_ID=$(read_value_from_config_file $EXECMODE)
CURRENT_IMAGE_ID=$(docker inspect --format '{{.Id}}' $IMAGE_NAME)

DOCKER_RUN_ARGS=" \
                --name $CONTAINER_NAME \
                -e NUID=$(id -u) -e NGID=$(id -g) \
                -u $CONTAINER_USER \
                -e DISPLAY -e QT_X11_NO_MITSHM=1 -v /tmp/.X11-unix:/tmp/.X11-unix \
                $ADDITIONAL_DOCKER_RUN_ARGS \
                $ADDITIONAL_DOCKER_MOUNT_ARGS \
                "

init_docker $@

# remove permission for local connections of root (docker daemon) to the current users x server
if command -v xhost > /dev/null; then
    xhost -local:root > /dev/null
fi

exit $DOCKER_EXEC_RETURN_VALUE
