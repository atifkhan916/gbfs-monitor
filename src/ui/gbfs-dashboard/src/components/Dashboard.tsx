import React, { useState, useEffect, useCallback } from 'react';
import { 
  LineChart, Line, XAxis, YAxis, CartesianGrid, 
  Tooltip, Legend, ResponsiveContainer 
} from 'recharts';
import { Card, CardHeader, CardTitle, CardContent } from '../components/ui/card';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '../components/ui/select';

interface BikeStats {
  provider_id: string;
  timestamp: number;
  total_bikes_available: number;
}

interface GroupedStats {
  timestamp: number;
  [key: string]: number;  // For provider_id keys
}

const COLORS = {
  'careem_bike': '#8884d8',
  'nextbike': '#82ca9d',
  'Ecobici': '#ffc658'
};

const Dashboard: React.FC = () => {
  const [stats, setStats] = useState<GroupedStats[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [timeRange, setTimeRange] = useState<string>("2");
  const [websocket, setWebsocket] = useState<WebSocket | null>(null);

  const wsUrl = 'wss://'+process.env.REACT_APP_WEBSOCKET_URL;

  const formatTime = (timestamp: number): string => {
    return new Date(timestamp * 1000).toLocaleTimeString([], { 
      hour: '2-digit', 
      minute: '2-digit' 
    });
  };

  const processData = (data: BikeStats[]): GroupedStats[] => {
    const groupedByTime = data.reduce((acc: { [key: number]: GroupedStats }, curr) => {
      if (!acc[curr.timestamp]) {
        acc[curr.timestamp] = {
          timestamp: curr.timestamp,
          [curr.provider_id]: curr.total_bikes_available
        };
      } else {
        acc[curr.timestamp][curr.provider_id] = curr.total_bikes_available;
      }
      return acc;
    }, {});

    return Object.values(groupedByTime).sort((a, b) => a.timestamp - b.timestamp);
  };

  const fetchData = useCallback(() => {
    if (!websocket || websocket.readyState !== WebSocket.OPEN) return;

    const endDate = new Date();
    const startDate = new Date(endDate.getTime() - (parseInt(timeRange) * 60 * 60 * 1000));

    console.log("Fetching data for range:", startDate.toISOString(), "to", endDate.toISOString());
    
    websocket.send(JSON.stringify({
      action: 'getBikeStats',
      startDate: startDate.toISOString(),
      endDate: endDate.toISOString()
    }));
  }, [websocket, timeRange]);

  const connectWebSocket = useCallback(() => {
    if (!wsUrl) {
      setError('WebSocket URL not configured');
      setLoading(false);
      return;
    }

    const ws = new WebSocket(wsUrl);

    ws.onopen = () => {
      console.log('Connected to WebSocket');
      setWebsocket(ws);
    };

    ws.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data);
        if (message.type === 'bikeStats') {
          const processedData = processData(message.data);
          setStats(processedData);
        } else if (message.type === 'error') {
          setError(message.message);
        }
        setLoading(false);
      } catch (error) {
        console.error('Error parsing message:', error);
        setError('Failed to parse data');
        setLoading(false);
      }
    };

    ws.onerror = (error) => {
      console.log('WebSocket error:', error);
      console.log('WebSocket error:', JSON.stringify(error));
      //setError('Connection error. Retrying...');
      setLoading(false);
    };

    return () => {
      ws.close();
      setWebsocket(null);
    };
  }, [wsUrl]);

  // Connect WebSocket
  useEffect(() => {
    const cleanup = connectWebSocket();
    return cleanup;
  }, [connectWebSocket]);

  // Fetch data when WebSocket connects or time range changes
  useEffect(() => {
    if (websocket?.readyState === WebSocket.OPEN) {
      fetchData();
    }
  }, [websocket, timeRange, fetchData]);

  const handleTimeRangeChange = (value: string) => {
    setTimeRange(value);
    setLoading(true);
  };

  // Generate hours array for dropdown
  const hours = Array.from({ length: 24 }, (_, i) => i + 1);

  return (
    <div className="p-6 bg-gray-50 min-h-screen">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-3xl font-bold">Bike Availability Dashboard</h1>
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium">Time Range:</span>
          <Select value={timeRange} onValueChange={handleTimeRangeChange}>
            <SelectTrigger className="w-32">
              <SelectValue placeholder="Select hours" />
            </SelectTrigger>
            <SelectContent>
              {hours.map((hour) => (
                <SelectItem key={hour} value={hour.toString()}>
                  {hour} {hour === 1 ? 'hour' : 'hours'}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {error && (
        <div className="mb-6 p-4 bg-red-100 text-red-700 rounded-lg">
          {error}
        </div>
      )}

      {loading ? (
        <div className="flex justify-center items-center h-64">
          <div className="animate-spin rounded-full h-32 w-32 border-b-2 border-blue-500"></div>
        </div>
      ) : (
        <Card className="w-full">
          <CardHeader>
            <CardTitle>Available Bikes by Provider (Last {timeRange} {parseInt(timeRange) === 1 ? 'Hour' : 'Hours'})</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="h-[600px]">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={stats}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis 
                    dataKey="timestamp" 
                    tickFormatter={formatTime}
                    interval={0}
                    angle={-45}
                    textAnchor="end"
                    height={60}
                  />
                  <YAxis 
                    label={{ 
                      value: 'Available Bikes', 
                      angle: -90, 
                      position: 'insideLeft' 
                    }} 
                  />
                  <Tooltip 
                    labelFormatter={formatTime}
                    formatter={(value: number) => [`${value} bikes`]}
                  />
                  <Legend />
                  {Object.entries(COLORS).map(([provider, color]) => (
                    <Line
                      key={provider}
                      type="monotone"
                      dataKey={provider}
                      name={provider}
                      stroke={color}
                      dot={false}
                      strokeWidth={2}
                    />
                  ))}
                </LineChart>
              </ResponsiveContainer>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
};

export default Dashboard;