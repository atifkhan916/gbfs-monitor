export interface WebSocketEvent {
    requestContext: {
      connectionId: string;
      routeKey: string;
    };
    body?: string;
  }
  
  export interface BikeStatsRequest {
    action: 'getBikeStats';
    startDate?: string; // YYYY-MM-DD
    endDate?: string;   // YYYY-MM-DD
    provider?: string;
  }
  
  export interface ConnectionItem {
    connectionId: string;
    timestamp: number;
  }
  
  export interface BikeStatsResponse {
    provider_id: string;
    timestamp: number;
    total_stations: number;
    total_capacity: number;
    total_bikes_available: number;
    total_docks_available: number;
    active_stations: number;
  }