const AWS = require('aws-sdk');
const autoscaling = new AWS.AutoScaling();
const ec2 = new AWS.EC2();

exports.handler = async (event) => {
  console.log('Status check request received:', JSON.stringify(event));
  
  // Enable CORS for browser requests
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key',
    'Access-Control-Allow-Methods': 'GET,OPTIONS',
    'Content-Type': 'application/json',
    'Cache-Control': 'no-cache, no-store, must-revalidate'
  };
  
  // Handle OPTIONS requests (for CORS preflight)
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({})
    };
  }
  
  // Get ASG name from environment variables
  const asgName = process.env.ASG_NAME;
  
  try {
    // Get the ASG information
    const asgInfo = await autoscaling.describeAutoScalingGroups({
      AutoScalingGroupNames: [asgName]
    }).promise();
    
    // Check if the ASG has any instances
    if (!asgInfo.AutoScalingGroups[0] || asgInfo.AutoScalingGroups[0].Instances.length === 0) {
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({
          status: 'stopped',
          message: 'No instances are currently running'
        })
      };
    }
    
    // Get instances in the ASG
    const instances = asgInfo.AutoScalingGroups[0].Instances;
    
    // If multiple instances somehow, just get the first one
    const instanceId = instances[0].InstanceId;
    
    // Get detailed information about the instance
    const instanceInfo = await ec2.describeInstances({
      InstanceIds: [instanceId]
    }).promise();
    
    // Extract instance details
    const instance = instanceInfo.Reservations[0]?.Instances[0];
    if (!instance) {
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({
          status: 'not_found',
          message: 'Instance not found'
        })
      };
    }
    
    // Determine instance status
    let status = instance.State.Name;
    let publicIp = instance.PublicIpAddress || null;
    let statusChecks = 'unknown';
    
    // If instance is running, check instance status for more detail
    if (status === 'running') {
      // Check status checks
      const statusInfo = await ec2.describeInstanceStatus({
        InstanceIds: [instanceId]
      }).promise();
      
      if (statusInfo.InstanceStatuses.length > 0) {
        const systemStatus = statusInfo.InstanceStatuses[0].SystemStatus.Status;
        const instanceStatus = statusInfo.InstanceStatuses[0].InstanceStatus.Status;
        
        if (systemStatus === 'ok' && instanceStatus === 'ok') {
          statusChecks = 'passed';
        } else {
          statusChecks = 'initializing';
          status = 'initializing';
        }
      } else {
        statusChecks = 'no_data';
        status = 'pending';
      }
    }
    
    // Return the instance status
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        status: status,
        instanceId: instanceId,
        publicIp: publicIp,
        statusChecks: statusChecks,
        launchTime: instance.LaunchTime,
        message: getStatusMessage(status, statusChecks)
      })
    };
  } catch (error) {
    console.error('Error checking instance status:', error);
    
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        status: 'error',
        message: 'Failed to check instance status. Please try again later.'
      })
    };
  }
};

// Helper function to generate user-friendly status messages
function getStatusMessage(status, statusChecks) {
  switch (status) {
    case 'running':
      return statusChecks === 'passed' 
        ? 'Your instance is running and ready to use!'
        : 'Your instance is running but still initializing...';
    case 'pending':
      return 'Your instance is starting up. This may take 1-2 minutes...';
    case 'stopping':
      return 'Your instance is shutting down.';
    case 'stopped':
      return 'Your instance is currently stopped. Click the Start button to start it.';
    case 'initializing':
      return 'Your instance is running but the services are still initializing...';
    default:
      return `Instance state: ${status}`;
  }
}