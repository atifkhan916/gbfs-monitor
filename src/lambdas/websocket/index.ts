  import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
  import { 
    DynamoDBDocumentClient, 
    QueryCommand, 
    PutCommand, 
    DeleteCommand 
  } from "@aws-sdk/lib-dynamodb";
  import { ApiGatewayManagementApiClient, PostToConnectionCommand } from "@aws-sdk/client-apigatewaymanagementapi";
  import { WebSocketEvent, BikeStatsRequest, BikeStatsResponse } from './types';

  const dynamodb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  const bikeStatsTable = process.env.BIKE_STATS_TABLE!;
  const connectionsTable = process.env.CONNECTIONS_TABLE!;

  const createApiGatewayClient = (event: WebSocketEvent) => {
    const endpoint = `https://${event.requestContext.domainName}/${event.requestContext.stage}`;
    return new ApiGatewayManagementApiClient({ endpoint });
  };

  async function handleConnect(connectionId: string): Promise<void> {
    console.log('Connected:', connectionId);
    await dynamodb.send(new PutCommand({
      TableName: connectionsTable,
      Item: {
        connection_id: connectionId,
        timestamp: Date.now()
      }
    }));
  }

  async function handleDisconnect(connectionId: string): Promise<void> {
    console.log('Disconnected:', connectionId);
    await dynamodb.send(new DeleteCommand({
      TableName: connectionsTable,
      Key: { connection_id: connectionId }
    }));
  }

  async function getBikeStats(startDateIso: string | undefined, endDateIso: string | undefined): Promise<BikeStatsResponse[]> {
    console.log('startDateIso: ', startDateIso, 'endDateIso', endDateIso);
    const now = Date.now();
    const oneHourAgo = now - (60 * 60 * 1000); // 1 hour in milliseconds
  
    // Convert ISO strings to timestamps, default to last hour if not provided
    const startTimestamp = startDateIso ? new Date(startDateIso).getTime() : oneHourAgo;
    const endTimestamp = endDateIso ? new Date(endDateIso).getTime() : now;
  
    // Get all dates that fall within the time range
    const dates = getDatesBetween(startTimestamp, endTimestamp);
    let allResults: BikeStatsResponse[] = [];
  
    try {
      // Query each date
      for (const date of dates) {
        const params = {
          TableName: bikeStatsTable,
          IndexName: "DateIndex",
          KeyConditionExpression: "#date = :date AND #ts BETWEEN :start AND :end",
          ExpressionAttributeNames: {
            "#date": "date",
            "#ts": "timestamp"
          },
          ExpressionAttributeValues: {
            ":date": date,
            ":start": Math.floor(startTimestamp/1000),
            ":end": Math.floor(endTimestamp/1000)
          }
        };
  
        console.log("Query params:", JSON.stringify(params, null, 2));
        const result = await dynamodb.send(new QueryCommand(params));
        
        if (result.Items) {
          allResults = allResults.concat(result.Items as BikeStatsResponse[]);
        }
      }
  
      // Sort results by timestamp
      return allResults.sort((a, b) => a.timestamp - b.timestamp);
    } catch (error) {
      console.error('Error querying bike stats:', error);
      throw error;
    }
  }

  function getDatesBetween(startTime: number, endTime: number): string[] {
    const dates = new Set<string>();
    let currentTime = startTime;
    
    while (currentTime <= endTime) {
      dates.add(getDateString(currentTime));
      // Add one day in milliseconds
      currentTime += 24 * 60 * 60 * 1000;
    }
    
    return Array.from(dates);
  }

  function getDateString(timestamp: number): string {
    return new Date(timestamp).toISOString().split('T')[0];
  }

  async function handleMessage(event: WebSocketEvent): Promise<void> {
    const connectionId = event.requestContext.connectionId;
    const body: BikeStatsRequest = JSON.parse(event.body || '{}');
    const apiGateway = createApiGatewayClient(event);

    try {
      if (body.action !== 'getBikeStats') {
        throw new Error('Invalid action');
      }

      const stats = await getBikeStats(
        body.startDate,
        body.endDate
      );

      console.log('bikeStats:', JSON.stringify(stats));
      await apiGateway.send(new PostToConnectionCommand({
        ConnectionId: connectionId,
        Data: JSON.stringify({
          type: 'bikeStats',
          data: stats
        })
      }));

    } catch (error) {
      console.error('Error processing message:', error);
      await apiGateway.send(new PostToConnectionCommand({
        ConnectionId: connectionId,
        Data: JSON.stringify({
          type: 'error',
          message: error instanceof Error ? error.message : 'Unknown error'
        })
      }));
    }
  }

  export const handler = async (event: WebSocketEvent) => {
    try {
      console.log('Event:', JSON.stringify(event, null, 2));
      switch (event.requestContext.routeKey) {
        case '$connect':
          await handleConnect(event.requestContext.connectionId);
          break;
        case '$disconnect':
          await handleDisconnect(event.requestContext.connectionId);
          break;
        case '$default':
          await handleMessage(event);
          break;
      }

      return { statusCode: 200, body: 'OK' };
    } catch (error) {
      console.error('Error:', error);
      return { statusCode: 500, body: 'Internal Server Error' };
    }
  };