import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import axios from 'axios';
import { BikeStats, GBFSProvider, GBFSResponse, StationInformation, StationStatusResponse } from "./types";

const s3Client = new S3Client({});

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
  const stations_data: BikeStats['stations_data'] = {};
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
      
      stations_data[station.station_id] = {
        name: station.name,
        capacity: station.capacity,
        bikes_available: status.num_bikes_available,
        docks_available: status.num_docks_available,
        is_active,
        lat: station.lat,
        lon: station.lon
      };
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
}

async function storeData(stats: BikeStats): Promise<void> {
  const s3Bucket = process.env.S3_BUCKET!;
  
  // Format date for partitioning
  const date = new Date(stats.timestamp * 1000);
  const isoDateTime = date.toISOString(); 

  // Extract components for partitioning
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');
  const hour = String(date.getUTCHours()).padStart(2, '0');

  // Prepare real-time data
  const realtimeData = {
    provider: stats.provider,
    total_stations: stats.total_stations,
    total_capacity: stats.total_capacity,
    total_bikes_available: stats.total_bikes_available,
    total_docks_available: stats.total_docks_available,
    active_stations: stats.active_stations,
    datetime: isoDateTime,
  };

  // Store in real-time folder for QuickSight
  await s3Client.send(new PutObjectCommand({
    Bucket: s3Bucket,
    Key: `realtime/current/${stats.provider}.json`,
    Body: JSON.stringify(realtimeData),
    ContentType: 'application/json'
  }));

  // Also store in historical data structure
  await s3Client.send(new PutObjectCommand({
    Bucket: s3Bucket,
    Key: `historical/year=${year}/month=${month}/day=${day}/hour=${hour}/${stats.provider}/${stats.timestamp}.json`,
    Body: JSON.stringify(realtimeData),
    ContentType: 'application/json'
  }));

  // Store current snapshot for API access
  await s3Client.send(new PutObjectCommand({
    Bucket: s3Bucket,
    Key: `realtime/latest/${stats.provider}_snapshot.json`,
    Body: JSON.stringify({
      ...realtimeData,
      last_updated: new Date().toISOString()
    }),
    ContentType: 'application/json'
  }));
}

export const handler = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const providers: GBFSProvider[] = JSON.parse(process.env.PROVIDERS!);
    console.log(`providers: ${JSON.stringify(providers)}`)
    const results = await Promise.allSettled(
      providers.map(async (provider) => {
        try {
          const stats = await collectProviderData(provider);
          await storeData(stats);
          return { 
            provider: provider.name, 
            status: 'success',
            total_bikes: stats.total_bikes_available,
            active_stations: stats.active_stations
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
    
    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Data collection completed',
        timestamp: Math.floor(Date.now() / 1000),
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