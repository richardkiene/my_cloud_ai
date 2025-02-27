const AWS = require('aws-sdk');
const autoscaling = new AWS.AutoScaling();

exports.handler = async (event) => {
  console.log('Start instance request received:', JSON.stringify(event));
  
  // Get ASG name from environment variables
  const asgName = process.env.ASG_NAME;
  
  try {
    // First check if the ASG already has instances
    const asgInfo = await autoscaling.describeAutoScalingGroups({
      AutoScalingGroupNames: [asgName]
    }).promise();
    
    // Get the current instances and their states
    const asgGroup = asgInfo.AutoScalingGroups[0];
    const runningInstances = asgGroup.Instances.filter(
      instance => ['InService', 'Pending', 'Pending:Wait', 'Pending:Proceed'].includes(instance.LifecycleState)
    );
    
    // If we already have running instances, just redirect to the status page
    if (runningInstances.length > 0) {
      console.log(`ASG ${asgName} already has ${runningInstances.length} running instances.`);
      return {
        statusCode: 302,
        headers: {
          'Location': `https://${event.headers.Host}/starting.html`,
          'Cache-Control': 'no-cache'
        },
        body: JSON.stringify({ message: 'Instance is already running or starting' })
      };
    }
    
    // If no running instances, increase desired capacity to 1
    if (asgGroup.DesiredCapacity === 0) {
      console.log(`Setting ASG ${asgName} desired capacity to 1`);
      await autoscaling.setDesiredCapacity({
        AutoScalingGroupName: asgName,
        DesiredCapacity: 1,
        HonorCooldown: false
      }).promise();
      
      console.log('Instance start initiated successfully');
    }
    
    // Redirect to the status page
    return {
      statusCode: 302,
      headers: {
        'Location': `https://${event.headers.Host}/starting.html`,
        'Cache-Control': 'no-cache'
      },
      body: JSON.stringify({ message: 'Instance startup initiated' })
    };
  } catch (error) {
    console.error('Error starting instance:', error);
    
    return {
      statusCode: 500,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-cache'
      },
      body: JSON.stringify({ error: 'Failed to start instance. Please try again later.' })
    };
  }
};