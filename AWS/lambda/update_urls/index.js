const AWS = require('aws-sdk');
const autoscaling = new AWS.AutoScaling();
const ssm = new AWS.SSM();

exports.handler = async (event) => {
    console.log('Update URLs Lambda triggered:', JSON.stringify(event));
    
    // Get environment variables
    const asgName = process.env.ASG_NAME;
    const apiGatewayUrl = process.env.API_GATEWAY_URL;
    const ssmParamName = process.env.SSM_PARAM_NAME;
    
    // Use the URL from the event if provided (for manual invocation)
    const urlToUse = event.apiGatewayUrl || apiGatewayUrl;
    
    if (!urlToUse) {
        console.error('No API Gateway URL provided!');
        return {
            statusCode: 500,
            body: 'No API Gateway URL provided'
        };
    }
    
    console.log(`Using API Gateway URL: ${urlToUse}`);
    
    try {
        // Update the SSM parameter with the API Gateway URL
        console.log(`Updating SSM parameter ${ssmParamName} with URL ${urlToUse}`);
        await ssm.putParameter({
            Name: ssmParamName,
            Value: urlToUse,
            Type: 'String',
            Overwrite: true
        }).promise();
        
        // Update the ASG tags with the API Gateway URLs
        console.log(`Updating ASG ${asgName} tags with API Gateway URLs`);
        
        const tagsToUpdate = [
            {
                ResourceId: asgName,
                ResourceType: 'auto-scaling-group',
                Key: 'ApiGatewayUrl',
                Value: urlToUse,
                PropagateAtLaunch: true
            },
            {
                ResourceId: asgName,
                ResourceType: 'auto-scaling-group',
                Key: 'ApiGatewayStartUrl',
                Value: `${urlToUse}/start`,
                PropagateAtLaunch: true
            },
            {
                ResourceId: asgName,
                ResourceType: 'auto-scaling-group',
                Key: 'ApiGatewayStatusUrl',
                Value: `${urlToUse}/status`,
                PropagateAtLaunch: true
            }
        ];
        
        await autoscaling.createOrUpdateTags({
            Tags: tagsToUpdate
        }).promise();
        
        console.log('Successfully updated all URLs');
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                message: 'URLs updated successfully',
                apiGatewayUrl: urlToUse,
                startUrl: `${urlToUse}/start`,
                statusUrl: `${urlToUse}/status`
            })
        };
    } catch (error) {
        console.error('Error updating URLs:', error);
        
        return {
            statusCode: 500,
            body: JSON.stringify({
                message: 'Error updating URLs',
                error: error.message
            })
        };
    }
};