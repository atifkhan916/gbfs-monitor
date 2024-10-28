import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const s3Client = new S3Client({});

export const handler = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const providers = JSON.parse(process.env.PROVIDERS || '[]');
    const s3Bucket = process.env.S3_BUCKET!;

    // Fetch latest data for all providers
    const providerData = await Promise.all(
      providers.map(async (provider: string) => {
        try {
          const response = await s3Client.send(new GetObjectCommand({
            Bucket: s3Bucket,
            Key: `realtime/latest/${provider}_snapshot.json`
          }));

          const body = await response.Body?.transformToString();
          return body ? JSON.parse(body) : null;
        } catch (error) {
          console.error(`Error fetching data for ${provider}:`, error);
          return null;
        }
      })
    );

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true
      },
      body: JSON.stringify({
        timestamp: Date.now(),
        providers: providerData.filter(Boolean)
      })
    };
  } catch (error) {
    console.error('Error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: 'Internal server error' })
    };
  }
};