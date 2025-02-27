const AWS = require('aws-sdk');
const ec2 = new AWS.EC2();
const autoscaling = new AWS.AutoScaling();
const sns = new AWS.SNS();

exports.handler = async (event) => {
    console.log('Event received:', JSON.stringify(event, null, 2));
    
    // Get environment variables
    const eipAllocationId = process.env.EIP_ALLOCATION_ID;
    const asgName = process.env.ASG_NAME;
    
    // Extract instance ID from the event
    const instanceId = event.detail.EC2InstanceId;
    
    // For scheduled events, we need to look up the instance ID from the ASG
    if (!instanceId) {
        try {
            const asgResponse = await autoscaling.describeAutoScalingGroups({
                AutoScalingGroupNames: [asgName]
            }).promise();
            
            const instances = asgResponse.AutoScalingGroups[0].Instances;
            if (instances.length === 0) {
                console.log('No instances found in ASG');
                return { statusCode: 200, body: 'No instances to associate EIP with' };
            }
            
            // Get the first instance in the ASG
            const asgInstanceId = instances[0].InstanceId;
            await associateElasticIp(eipAllocationId, asgInstanceId);
            return { statusCode: 200, body: `Associated EIP with instance ${asgInstanceId}` };
        } catch (error) {
            console.error('Error processing scheduled event:', error);
            return { statusCode: 500, body: 'Error processing scheduled event' };
        }
    }
    
    // If we have an instance ID from the event, use that
    try {
        console.log(`Associating EIP ${eipAllocationId} with instance ${instanceId}`);
        
        // Wait until the instance is in a valid state before associating the EIP
        await waitForInstanceRunning(instanceId);
        
        // Associate the EIP with the instance
        await associateElasticIp(eipAllocationId, instanceId);
        
        console.log('EIP association successful');
        return { statusCode: 200, body: 'EIP association successful' };
    } catch (error) {
        console.error('Error associating EIP:', error);
        
        // Try to notify about the failure
        try {
            await notifyFailure(instanceId, error.message);
        } catch (snsError) {
            console.error('Error sending SNS notification:', snsError);
        }
        
        return { statusCode: 500, body: 'Error associating EIP' };
    }
};

// Function to wait until the instance is running
async function waitForInstanceRunning(instanceId) {
    console.log(`Waiting for instance ${instanceId} to be running...`);
    
    const params = {
        InstanceIds: [instanceId]
    };
    
    let retries = 0;
    const maxRetries = 30;
    const sleepTime = 10000; // 10 seconds
    
    while (retries < maxRetries) {
        try {
            const data = await ec2.describeInstances(params).promise();
            const state = data.Reservations[0].Instances[0].State.Name;
            
            console.log(`Instance state: ${state}`);
            
            if (state === 'running') {
                // Wait a bit more to ensure the instance is fully initialized
                await sleep(5000);
                return;
            }
            
            if (state === 'terminated' || state === 'shutting-down') {
                throw new Error(`Instance ${instanceId} is ${state}, cannot proceed with EIP association`);
            }
        } catch (error) {
            console.error(`Error checking instance state (retry ${retries}):`, error);
            if (error.code === 'InvalidInstanceID.NotFound') {
                throw new Error(`Instance ${instanceId} not found`);
            }
        }
        
        retries++;
        await sleep(sleepTime);
    }
    
    throw new Error(`Timed out waiting for instance ${instanceId} to be running`);
}

// Function to associate the EIP with the instance
async function associateElasticIp(allocationId, instanceId) {
    // First, check if the EIP is already associated with this instance
    const currentAssociation = await ec2.describeAddresses({
        AllocationIds: [allocationId]
    }).promise();
    
    const address = currentAssociation.Addresses[0];
    if (address.InstanceId === instanceId) {
        console.log(`EIP ${allocationId} is already associated with instance ${instanceId}`);
        return;
    }
    
    // If there's an existing association, but with a different instance, disassociate it
    if (address.AssociationId) {
        console.log(`Disassociating EIP ${allocationId} from instance ${address.InstanceId}`);
        await ec2.disassociateAddress({
            AssociationId: address.AssociationId
        }).promise();
    }
    
    // Associate the EIP with the new instance
    console.log(`Associating EIP ${allocationId} with instance ${instanceId}`);
    const response = await ec2.associateAddress({
        AllocationId: allocationId,
        InstanceId: instanceId,
        AllowReassociation: true
    }).promise();
    
    console.log('Association response:', JSON.stringify(response));
    return response;
}

// Helper function to implement sleep
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

// Function to send a notification when EIP association fails
async function notifyFailure(instanceId, errorMessage) {
    // Get the SNS topic from environment variables or use a default
    const topicArn = process.env.SNS_TOPIC_ARN;
    if (!topicArn) {
        console.log('No SNS topic configured for notifications');
        return;
    }
    
    const params = {
        TopicArn: topicArn,
        Subject: 'EIP Association Failure',
        Message: `Failed to associate Elastic IP with instance ${instanceId}. Error: ${errorMessage}`
    };
    
    return sns.publish(params).promise();
}