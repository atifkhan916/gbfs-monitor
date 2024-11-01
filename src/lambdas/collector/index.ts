import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import axios from 'axios';
import { BikeStats, GBFSProvider, GBFSResponse, StationInformation, StationStatusResponse } from "./types";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);


export const handler = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const providers: GBFSProvider[] = JSON.parse(process.env.PROVIDERS!);
    console.log(`Processing ${providers.length} providers`);

    const results = await Promise.allSettled(
      providers.map(async (provider) => {
        try {
          const stats = await collectProviderData(provider);
          await storeStats(stats);
          return { 
            provider: provider.name, 
            status: 'success',
            total_bikes: stats.total_bikes_available,
            active_stations: stats.active_stations,
            timestamp: stats.timestamp
          };
        } catch (error) {
          console.error(`Error processing ${provider.name}:`, error);
          return { 
            provider: provider.name, 
            status: 'error', 
            error: error instanceof Error ? error.message : 'Unknown error' 
          };
        }
      })
    );
    
    const successCount = results.filter(r => r.status === 'fulfilled').length;
    const failureCount = results.filter(r => r.status === 'rejected').length;

    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Data collection completed',
        timestamp: Math.floor(Date.now() / 1000),
        summary: {
          total: providers.length,
          success: successCount,
          failed: failureCount
        },
        results
      })
    };
    
  } catch (error) {
    console.error('Fatal error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({
        message: 'Internal server error',
        error: error instanceof Error ? error.message : 'Unknown error'
      })
    };
  }
};

async function fetchGBFSData(url: string): Promise<GBFSResponse> {
  const response = await axios.get<GBFSResponse>(url);
  return response.data;
}

async function fetchStationInformation(url: string): Promise<StationInformation> {
  const response = await axios.get<StationInformation>(url);
  return response.data;
}

async function fetchStationStatus(url: string): Promise<StationStatusResponse> {
  const response = await axios.get<StationStatusResponse>(url);
  return response.data;
}

async function collectProviderData(provider: GBFSProvider): Promise<BikeStats> {
  const timestamp = Math.floor(Date.now() / 1000);
  
  try {
    // Fetch GBFS feed data
    const gbfsData = await fetchGBFSData(provider.url);
    let feeds = gbfsData.data.en?.feeds;
    if(!feeds) {
      feeds = gbfsData.data.feeds;
      if(!feeds) {
        feeds = gbfsData.data.de?.feeds;
      }
    }
    if(!feeds) {
      throw new Error(`No feeds found for provider ${provider.name}`);
    }

    // Get station information and status URLs
    const stationInfoUrl = feeds.find(f => f.name === 'station_information')?.url;
    const stationStatusUrl = feeds.find(f => f.name === 'station_status')?.url;
    
    if (!stationInfoUrl || !stationStatusUrl) {
      throw new Error(`Required feeds not found for provider ${provider.name}`);
    }
    
    // Fetch station information and status
    const [stationInfo, stationStatus] = await Promise.all([
      fetchStationInformation(stationInfoUrl),
      fetchStationStatus(stationStatusUrl)
    ]);
    
    // Process and combine the data
    let total_bikes_available = 0;
    let total_docks_available = 0;
    let active_stations = 0;
    let total_capacity = 0;
    
    stationInfo.data.stations.forEach(station => {
      const status = stationStatus.data.stations.find(
        s => s.station_id === station.station_id
      );
      
      if (status) {
        const is_active = status.is_installed && status.is_renting && status.is_returning;
        
        if (is_active) {
          active_stations++;
          total_bikes_available += status.num_bikes_available;
          total_docks_available += status.num_docks_available;
        }
        
        total_capacity += station.capacity;
      }
    });
    
    return {
      provider: provider.name,
      timestamp,
      total_stations: stationInfo.data.stations.length,
      total_capacity,
      total_bikes_available,
      total_docks_available,
      active_stations
    };
  } catch (error) {
    console.error(`Error collecting data for provider ${provider.name}:`, error);
    throw error;
  }
}

export async function storeStats(stats: BikeStats): Promise<void> {
  const tableName = process.env.DYNAMODB_TABLE!;
  const retentionDays = parseInt(process.env.RETENTION_DAYS || '30');
  const now = Math.floor(Date.now() / 1000);
  
  const item = {
    provider_id: stats.provider,
    timestamp: stats.timestamp,
    date: new Date(stats.timestamp * 1000).toISOString().split('T')[0],
    expiry_time: now + (retentionDays * 24 * 60 * 60),
    total_stations: stats.total_stations,
    total_capacity: stats.total_capacity,
    total_bikes_available: stats.total_bikes_available,
    total_docks_available: stats.total_docks_available,
    active_stations: stats.active_stations,
    last_updated: now
  };

  await docClient.send(new PutCommand({
    TableName: tableName,
    Item: item
  }));
}
