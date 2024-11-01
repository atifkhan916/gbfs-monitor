import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
    DynamoDBDocumentClient,
    QueryCommand,
    QueryCommandInput,
    BatchWriteCommand,
    BatchWriteCommandInput,
    ScanCommand,
    ScanCommandInput
} from "@aws-sdk/lib-dynamodb";

const CONFIG = {
    BATCH_SIZE: 25,
    MAX_RETRIES: 3,
    RETRY_DELAY_MS: 1000,
    DEFAULT_RETENTION_DAYS: 30
  } as const;
  
interface Provider {
    provider_id: string;
}

export interface GBFSProvider {
    name: string;
    url: string;
  }

// Initialize DynamoDB clients
const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);

class CleanupError extends Error {
constructor(message: string, public readonly context?: any) {
    super(message);
    this.name = 'CleanupError';
}
}

export async function handler(event: any): Promise<{ statusCode: number; body: string }> {
const tableName = process.env.DYNAMODB_TABLE;
if (!tableName) {
    throw new CleanupError('DYNAMODB_TABLE environment variable is not set');
}

const retentionDays = parseInt(process.env.RETENTION_DAYS || String(CONFIG.DEFAULT_RETENTION_DAYS));
const cutoffTime = Date.now() - (retentionDays * 24 * 60 * 60 * 1000);

try {
    // Get all providers
    const providers: GBFSProvider[] = JSON.parse(process.env.PROVIDERS!);
    console.log(`providers: ${JSON.stringify(providers)}`)
    console.log(`Found ${providers.length} providers to process`);

    // Process each provider
    for (const provider of providers) {
        await cleanupProviderData(tableName, provider.name, cutoffTime);
    }

    return {
    statusCode: 200,
    body: JSON.stringify({
        message: 'Cleanup completed successfully',
        providersProcessed: providers.length
    })
    };
} catch (error) {
    console.error('Error during cleanup:', error);
    throw new CleanupError(
    'Failed to complete cleanup process',
    { error: error instanceof Error ? error.message : 'Unknown error' }
    );
}
}

async function getAllProviders(tableName: string): Promise<Provider[]> {
    const providers = new Set<string>();
    let lastEvaluatedKey: Record<string, any> | undefined;

    do {
        const scanParams: ScanCommandInput = {
            TableName: tableName,
            ProjectionExpression: 'provider_id',
            Select: 'SPECIFIC_ATTRIBUTES'
        };

        if (lastEvaluatedKey) {
            scanParams.ExclusiveStartKey = lastEvaluatedKey;
        }

        const response = await docClient.send(new ScanCommand(scanParams));
        response.Items?.forEach(item => {
        if (item.provider_id) {
            providers.add(item.provider_id);
        }
        });

        lastEvaluatedKey = response.LastEvaluatedKey;
    } while (lastEvaluatedKey);

    return Array.from(providers).map(id => ({ provider_id: id }));
}

async function cleanupProviderData(
    tableName: string,
    providerId: string,
    cutoffTime: number
    ): Promise<void> {
    let lastEvaluatedKey: Record<string, any> | undefined;
    let deletedCount = 0;

    try {
        do {
        // Query old items for this provider
        const queryParams: QueryCommandInput = {
            TableName: tableName,
            KeyConditionExpression: 'provider_id = :pid AND #ts < :cutoff',
            ExpressionAttributeNames: {
            '#ts': 'timestamp'
            },
            ExpressionAttributeValues: {
            ':pid': providerId,
            ':cutoff': cutoffTime
            },
            ExclusiveStartKey: lastEvaluatedKey
        };

        const queryResult = await docClient.send(new QueryCommand(queryParams));
        
        if (queryResult.Items && queryResult.Items.length > 0) {
            // Process items in batches
            const batches = chunkArray(queryResult.Items, CONFIG.BATCH_SIZE);
            
            for (const batch of batches) {
                await deleteItemsBatch(tableName, batch);
                deletedCount += batch.length;
            }
        }

            lastEvaluatedKey = queryResult.LastEvaluatedKey;
        } while (lastEvaluatedKey);

        console.log(`Successfully cleaned up ${deletedCount} items for provider ${providerId}`);
    } catch (error) {
        throw new CleanupError(
        `Failed to cleanup data for provider ${providerId}`,
        { error: error instanceof Error ? error.message : 'Unknown error' }
        );
    }
}

async function deleteItemsBatch(
    tableName: string,
    items: any[]
    ): Promise<void> {
    const deleteRequests = items.map(item => ({
        DeleteRequest: {
        Key: {
            provider_id: item.provider_id,
            timestamp: item.timestamp
        }
        }
    }));

    const batchWriteParams: BatchWriteCommandInput = {
        RequestItems: {
        [tableName]: deleteRequests
        }
    };

    let retries = 0;
    let unprocessedItems = batchWriteParams;

    while (retries < CONFIG.MAX_RETRIES) {
        try {
        const result = await docClient.send(new BatchWriteCommand(unprocessedItems));
        
        if (!result.UnprocessedItems || Object.keys(result.UnprocessedItems).length === 0) {
            break;
        }

        unprocessedItems = {
            RequestItems: result.UnprocessedItems
        };
        retries++;
        
        if (retries < CONFIG.MAX_RETRIES) {
            await sleep(CONFIG.RETRY_DELAY_MS * retries);
        }
        } catch (error) {
        throw new CleanupError(
            'Failed to process batch delete',
            { error: error instanceof Error ? error.message : 'Unknown error', items }
        );
        }
    }

    if (retries === CONFIG.MAX_RETRIES) {
        throw new CleanupError(
        'Max retries reached for batch delete',
        { unprocessedItems }
        );
    }
}

function chunkArray<T>(array: T[], size: number): T[][] {
    const chunks: T[][] = [];
    for (let i = 0; i < array.length; i += size) {
        chunks.push(array.slice(i, i + size));
    }
    return chunks;
}

function sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
}