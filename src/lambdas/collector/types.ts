// types.ts
export interface GBFSProvider {
  name: string;
  url: string;
}

export interface GBFSResponse {
  data: {
    en?: {
      feeds: Feed[];
    };
    de?: {
      feeds: Feed[];
    };
    feeds?: Feed[];
  };
}

export interface Feed {
  name: string;
  url: string;
}

export interface StationInformation {
  data: {
    stations: Station[];
  };
}

export interface Station {
  station_id: string;
  name: string;
  capacity: number;
  lat: number;
  lon: number;
}

export interface StationStatusResponse {
  data: {
    stations: StationStatus[];
  };
}

export interface StationStatus {
  station_id: string;
  num_bikes_available: number;
  num_docks_available: number;
  is_installed: boolean;
  is_renting: boolean;
  is_returning: boolean;
}

export interface BikeStats {
  provider: string;
  timestamp: number;
  total_stations: number;
  total_capacity: number;
  total_bikes_available: number;
  total_docks_available: number;
  active_stations: number;
}