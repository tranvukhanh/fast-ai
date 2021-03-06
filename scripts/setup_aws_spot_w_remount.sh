#!/bin/bash

#============================================================
#    FILE:  setup_aws_spot_w_remount.sh
#
#    USAGE:  . setup_aws_spot_w_remount.sh
#
#    DESCRIPTION: sets up a new aws spot instance and
#                 mounts an existing volume to root
#                 1) Reqest new AWS Spot Instance
#                 2) Attach existing volume to new instance
#                 3) Execute remount-root-script on new instance
#                 4) Login to new instance
#
#    PREREQUISITES:
#    - there exists an aws volume named as AWS_ROOT_VOL_NAME below
#    - configure specification.json to meet your needs and set the
#      corresponding file name in AWS_CONF_FILE variable
#    - set AWS_MAX_SPOT_PRICE below
#    - set AWS_PEM_KEY to your ssh key file
#    - spot instance OS must match volume OS
#
#    PLEASE NOTE:
#    - Swapping the root volume is a potentially dangerous operation!
#    - Please test the script on a non-critical volume before using
#      for critical data
#    - spot instance must be set up in same availability zone as volume!
#    - default specification.json is set up to create spot instance with
#          + AMI of OS Ubuntu Server 16.04 LTS (HVM)
#          + Instance type p2.xlarge
#          + Availability zone us-west-2b
#    - Script saves environment variables in a file .aws_spot_profile
#      which is used by remove_aws_spot.sh
#
#    AUTHOR:  Jonas Pettersson, j.g.f.pettersson@gmail.com
#    CREATED:  26/02/2017
#============================================================

# Name of the AWS Volume to mount
AWS_ROOT_VOL_NAME="spot"

AWS_MAX_SPOT_PRICE="0.5"
echo "AWS_MAX_SPOT_PRICE="${AWS_MAX_SPOT_PRICE}

# launch-specification file with JSON syntax described here:
# http://docs.aws.amazon.com/cli/latest/reference/ec2/request-spot-instances.html
AWS_CONF_FILE="file://specification_eu.json"
echo "AWS_CONF_FILE="${AWS_CONF_FILE}

AWS_PEM_KEY="aws-key-eu.pem"
echo "AWS_PEM_KEY="${AWS_PEM_KEY}

# Fetch AWS Volume ID
AWS_ROOT_VOLUME_ID=`aws ec2 describe-volumes --filters Name=tag-key,Values="Name" Name=tag-value,Values="$AWS_ROOT_VOL_NAME" --query="Volumes[*].VolumeId" --output="text"`
if [ -z ${AWS_ROOT_VOLUME_ID+x} ]; then
    echo -e "Could not fetch AWS_ROOT_VOLUME_ID\nExiting"; exit 1
else
    echo "AWS_ROOT_VOLUME_ID="${AWS_ROOT_VOLUME_ID}
fi

# Fetch AWS Availability Zone of the AWS Volume
# export AWS_AVAILABILITY_ZONE=`aws ec2 describe-volumes --volume-ids $AWS_ROOT_VOLUME_ID --query="Volumes[*].AvailabilityZone"`
# echo "AWS_AVAILABILITY_ZONE="${AWS_AVAILABILITY_ZONE}

# If setting up a spot fleet, use these lines (not thoroughly tested).
# Please note that configuration file has another format!
# AWS_SPOT_REQUEST_ID=$(aws ec2 request-spot-fleet --spot-fleet-request-config $AWS_CONF_FILE)
# echo "AWS_SPOT_REQUEST_ID="${AWS_SPOT_REQUEST_ID}

echo "Requesting new AWS Spot Instance"
AWS_SPOT_REQUEST_ID=`aws ec2 request-spot-instances --spot-price $AWS_MAX_SPOT_PRICE --launch-specification $AWS_CONF_FILE --query="SpotInstanceRequests[*].SpotInstanceRequestId" --output="text"`
if [ -z ${AWS_SPOT_REQUEST_ID+x} ]; then
    echo -e "Could not fetch AWS_SPOT_REQUEST_ID\nExiting"; exit 1
else
    echo "AWS_SPOT_REQUEST_ID="${AWS_SPOT_REQUEST_ID}
fi
# Note that the exported AWS_SPOT_REQUEST_ID is needed by the remove_aws_spot.sh script when terminating!

echo "Waiting for AWS Spot Request to fulfill"
aws ec2 wait spot-instance-request-fulfilled --spot-instance-request-ids $AWS_SPOT_REQUEST_ID

# Fetch AWS Instance ID of the newly created AWS Spot Instance
# Note that the exported AWS_INSTANCE_ID is needed by the remove_aws_spot.sh script when terminating!
AWS_INSTANCE_ID=`aws ec2 describe-spot-instance-requests --filters Name=spot-instance-request-id,Values=$AWS_SPOT_REQUEST_ID --query="SpotInstanceRequests[*].InstanceId" --output="text"`
if [ -z ${AWS_INSTANCE_ID+x} ]; then
    echo -e "Could not fetch AWS_INSTANCE_ID\nExiting"; exit 1
else
    echo "AWS_INSTANCE_ID="${AWS_INSTANCE_ID}
fi

echo "Waiting for AWS Spot Instance to start and initialize"
aws ec2 wait instance-status-ok --instance-ids $AWS_INSTANCE_ID

# Fetch AWS Volume ID of the newly created AWS Spot Instance
# Note that the exported AWS_VOLUME_ID is needed by the remove_aws_spot.sh script when terminating!
AWS_VOLUME_ID=`aws ec2 describe-instances --instance-ids $AWS_INSTANCE_ID --query="Reservations[*].Instances[*].BlockDeviceMappings[*].Ebs.VolumeId"`
echo "AWS_VOLUME_ID="${AWS_VOLUME_ID}

echo "Attaching existing AWS Volume to new AWS Instance"
aws ec2 attach-volume --volume-id $AWS_ROOT_VOLUME_ID --instance-id $AWS_INSTANCE_ID --device /dev/sdf
echo "Waiting for AWS Volume to attach and initialize"
aws ec2 wait volume-in-use --volume-ids $AWS_ROOT_VOLUME_ID

# Fetch Public DNS of new AWS Instance
AWS_INSTANCE_PUBLIC_DNS=`aws ec2 describe-instances --instance-ids $AWS_INSTANCE_ID --query="Reservations[*].Instances[*].PublicDnsName"`
if [ -z ${AWS_INSTANCE_PUBLIC_DNS+x} ]; then
    echo -e "Could not fetch AWS_INSTANCE_PUBLIC_DNS\nExiting"; exit 1
else
    echo "AWS_INSTANCE_PUBLIC_DNS="${AWS_INSTANCE_PUBLIC_DNS}
fi

echo "Fething remount-script to new AWS Instance"
ssh -i ~/.ssh/$AWS_PEM_KEY ubuntu@$AWS_INSTANCE_PUBLIC_DNS "wget https://raw.githubusercontent.com/jonas-pettersson/fast-ai/master/scripts/remount_root.sh"
ssh -i ~/.ssh/$AWS_PEM_KEY ubuntu@$AWS_INSTANCE_PUBLIC_DNS "chmod +x ~/remount_root.sh"

echo "Executing remount-script on new AWS Instance"
ssh -i ~/.ssh/$AWS_PEM_KEY ubuntu@$AWS_INSTANCE_PUBLIC_DNS "sudo ~/remount_root.sh"

echo "Waiting for AWS Spot Instance to reboot"
aws ec2 wait instance-status-ok --instance-ids $AWS_INSTANCE_ID

# It is necessary to remove the SSH key because we have a new volume - otherwise they will not match
echo "Remove all SSH keys belonging to new instance from known_hosts file"
ssh-keygen -R $AWS_INSTANCE_PUBLIC_DNS

echo "Please give the AWS Instance some time (~30 sec) to get initialized after reboot"
echo "Then login using following command:"
echo "ssh -i ~/.ssh/$AWS_PEM_KEY ubuntu@$AWS_INSTANCE_PUBLIC_DNS"

cat > .aws_spot_profile << EOF11
AWS_SPOT_REQUEST_ID=${AWS_SPOT_REQUEST_ID}
AWS_INSTANCE_ID=${AWS_INSTANCE_ID}
AWS_VOLUME_ID=${AWS_VOLUME_ID}
AWS_INSTANCE_PUBLIC_DNS=${AWS_INSTANCE_PUBLIC_DNS}
EOF11

echo "Following variables were saved in .aws_spot_profile"
cat .aws_spot_profile