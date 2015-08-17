#import <Foundation/Foundation.h>
#import "SWGApiClient.h"

@interface SWGApi : NSObject

@property (nonatomic, strong, readonly) SWGApiClient *apiClient;
@property (nonatomic, strong, readonly) NSString *basePath;
@property (nonatomic, strong, readonly) NSDictionary *defaultHeaders;

+ (instancetype) apiWithBasePath:(NSString *)basePath;

-(void) setHeader:(NSString*)value forKey:(NSString*)key;

-(unsigned long) requestQueueSize;

@end