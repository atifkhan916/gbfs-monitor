export interface GBFSProvider {
    name: string;
    url: string;
  }
  
  export interface GBFSFeed {
    name: string;
    url: string;
  }
  
  export interface GBFSResponse {
    last_updated: number;
    ttl: number;
    data: {
      en: {
        feeds: GBFSFeed[];
      };
    };
    version: string;
  }
  
  export interface Station {
    station_id: string;
    name: string;
    short_name: string;
    lat: number;
    lon: number;
    capacity: number;
    region_id: string;
    rental_methods: string[];
    parking_type: string;
    is_virtual_station: boolean;
    is_charging_station: boolean;
  }
  
  export interface StationInformation {
    last_updated: number;
    ttl: number;
    data: {
      stations: Station[];
    };
    version: string;
  }
  
  export interface StationVehicle {
    vehicle_type_id: string;
    count: number;
  }

  export interface StationDock {
    vehicle_type_ids: string;
    count: number;
  }

  export interface StationStatus {
    station_id: string;
    num_bikes_available: number;
    num_docks_available: number;
    num_docks_disabled:  number;
    num_vehicles_available: number;
    num_vehicles_disabled: number;
    vehicle_types_available: StationVehicle[];
    vehicle_docks_available: StationDock[];
    is_installed: boolean;
    is_renting: boolean;
    is_returning: boolean;
    last_reported: string;
  }
  
  export interface StationStatusResponse {
    last_updated: number;
    ttl: number;
    data: {
      stations: StationStatus[];
    };
    version: string;
  }
  
  export interface BikeStats {
    provider: string;
    timestamp: number;
    total_stations: number;
    total_capacity: number;
    total_bikes_available: number;
    total_docks_available: number;
    active_stations: number;
    stations_data?: {
      [key: string]: {
        name: string;
        capacity: number;
        bikes_available: number;
        docks_available: number;
        is_active: boolean;
        lat: number;
        lon: number;
      };
    };
  }
