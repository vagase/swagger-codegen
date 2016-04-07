#import "SWGApiClient.h"
#import "SWGFile.h"
#import "SWGQueryParamCollection.h"
#import "SWGConfiguration.h"


NSString *const SWGResponseObjectErrorKey = @"SWGResponseObject";

static long requestId = 0;
static NSMutableDictionary *queuedRequestsDict = nil;
static BOOL gLogRequests = NO;
static LogRequestsFilterBlock gLogRequestsFilterBlock = nil;

#pragma mark -

@implementation SWGApiClient(private)

- (void) _logResponseWithId:(NSNumber *)requestId
                  operation:(AFHTTPRequestOperation *)operation
                   duration:(NSTimeInterval)duration
                decodedData:(id)decodedData
                      error:(NSError *)error {
    if (![SWGApiClient logRequests]) {
        return;
    }

    NSURLRequest *request = operation.request;

    if (gLogRequestsFilterBlock && !gLogRequestsFilterBlock(self, request, decodedData, error)) {
        return;
    }

    NSString *requestURLStr = [request.URL absoluteString];
    long long durationMS = (long long)(duration * 1000L);

    @try {
        if (error) {
            DDLogDebug(@"[SWGApiClient] request[#%@][%lldms] %@ - response error: %@ ", requestId, durationMS, requestURLStr, error);
        }
        else {
            NSString *dataString = nil;
            NSUInteger dataLength = operation.responseData.length;

            if (decodedData) {
                NSData *dataObj = nil;

                if ([decodedData isKindOfClass:NSData.class]) {
                    dataObj = decodedData;
                }
                else if ([NSJSONSerialization isValidJSONObject:decodedData]){
                    NSError *jsonError = nil;
                    dataObj = [NSJSONSerialization dataWithJSONObject:decodedData
                                                              options:0
                                                                error:&jsonError];
                    if (jsonError) {
                        DDLogDebug(@"[SWGApiClient] error while encode object to data:%@ - %@", error, decodedData);
                        dataObj = nil;
                    }
                }

                if (dataObj) {
                    dataString = [[NSString alloc] initWithData:dataObj
                                                       encoding:NSUTF8StringEncoding];
                }
            }

            DDLogDebug(@"[SWGApiClient] request[#%@][%lldms][%lldbyte] %@ - response data:⏎\n%@ ",
                    requestId,
                    durationMS,
                    (long long)dataLength,
                    requestURLStr,
                    dataString ? dataString : decodedData);
        }
    }
    @catch (NSException *exception) {
        // forbid any unexpected exception to crash the app
        DDLogDebug(@"[SWGApiClient] exception occured while logging requset[%@] resposne[%@] exception[%@]", requestURLStr, decodedData, exception);
    }
}

- (NSNumber *) _genNextRequestId {
    long nextId = 0;

    @synchronized(queuedRequestsDict) {
        nextId = ++requestId;
    }

    return @(nextId);
}

- (void) _queueRequestOperation:(AFHTTPRequestOperation *)requestOperation
                         withId:(NSNumber *) requestId{
    @synchronized(queuedRequestsDict) {
        [queuedRequestsDict setObject:requestOperation forKey:requestId];
    }
}

- (AFHTTPRequestOperation *) _finishRequestWithId:(NSNumber*) requestId {
    AFHTTPRequestOperation *result = nil;

    @synchronized(queuedRequestsDict) {
        result = [queuedRequestsDict objectForKey:requestId];
        if (result) {
            [queuedRequestsDict removeObjectForKey:requestId];
        }
    }

    return result;
}

@end

#pragma mark -

@implementation SWGApiClient

+(SWGApiClient *)sharedClientFromPool:(NSString *)baseUrl {
    SWGApiClient *result = nil;

    @synchronized(self) {
        if (!queuedRequestsDict) {
            queuedRequestsDict = [[NSMutableDictionary alloc]init];
        }

        static NSMutableDictionary *pool = nil;
        if(pool == nil) {
            pool = [[NSMutableDictionary alloc] init];
        }

        result = [pool objectForKey:baseUrl];
        if (!result) {
            result = [[SWGApiClient alloc] initWithBaseURL:[NSURL URLWithString:baseUrl]];
            [pool setValue:result forKey:baseUrl];
        }
    }

    return result;
}

-(id)initWithBaseURL:(NSURL *)url {
    if (self = [super initWithBaseURL:url]) {
        self.requestSerializer = [AFJSONRequestSerializer serializer];
        self.responseSerializer = [AFJSONResponseSerializer serializer];
    }

    return self;
}

+ (BOOL) logRequests {
    return gLogRequests;
}

+ (void) setLogRequests:(BOOL)logRequests {
    gLogRequests = logRequests;
}

+ (void) setLogRequestsFilterBlock:(LogRequestsFilterBlock)filterBlock {
    gLogRequestsFilterBlock = filterBlock;
}

/*
 * Detect `Accept` from accepts
 */
+ (NSString *) selectHeaderAccept:(NSArray *)accepts
{
    if (accepts == nil || [accepts count] == 0) {
        return @"application/json";
    }

    NSMutableArray *lowerAccepts = [[NSMutableArray alloc] initWithCapacity:[accepts count]];
    [accepts enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [lowerAccepts addObject:[obj lowercaseString]];
    }];


    if ([lowerAccepts containsObject:@"application/json"]) {
        return @"application/json";
    }
    else {
        return [lowerAccepts componentsJoinedByString:@", "];
    }
}

/*
 * Detect `Content-Type` from contentTypes
 */
+ (NSString *) selectHeaderContentType:(NSArray *)contentTypes
{
    if (contentTypes == nil || [contentTypes count] == 0) {
        return @"application/json";
    }

    NSMutableArray *lowerContentTypes = [[NSMutableArray alloc] initWithCapacity:[contentTypes count]];
    [contentTypes enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [lowerContentTypes addObject:[obj lowercaseString]];
    }];

    if ([lowerContentTypes containsObject:@"application/json"]) {
        return @"application/json";
    }
    else {
        return lowerContentTypes[0];
    }
}

+(unsigned long)requestQueueSize {
    return [queuedRequestsDict count];
}

+(NSString*) escape:(id)unescaped {
    if([unescaped isKindOfClass:[NSString class]]){
        return (NSString *)CFBridgingRelease
        (CFURLCreateStringByAddingPercentEscapes(
                                                 NULL,
                                                 (__bridge CFStringRef) unescaped,
                                                 NULL,
                                                 (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                                 kCFStringEncodingUTF8));
    }
    else {
        return [NSString stringWithFormat:@"%@", unescaped];
    }
}

-(NSString*) pathWithQueryParamsToString:(NSString*) path
                             queryParams:(NSDictionary*) queryParams {
    NSString * separator = nil;
    int counter = 0;

    NSMutableString * requestUrl = [NSMutableString stringWithFormat:@"%@", path];
    if(queryParams != nil){
        for(NSString * key in [queryParams keyEnumerator]){
            if(counter == 0) separator = @"?";
            else separator = @"&";
            id queryParam = [queryParams valueForKey:key];
            if([queryParam isKindOfClass:[NSString class]]){
                [requestUrl appendString:[NSString stringWithFormat:@"%@%@=%@", separator,
                                          [SWGApiClient escape:key], [SWGApiClient escape:[queryParams valueForKey:key]]]];
            }
            else if([queryParam isKindOfClass:[SWGQueryParamCollection class]]){
                SWGQueryParamCollection * coll = (SWGQueryParamCollection*) queryParam;
                NSArray* values = [coll values];
                NSString* format = [coll format];

                if([format isEqualToString:@"csv"]) {
                    [requestUrl appendString:[NSString stringWithFormat:@"%@%@=%@", separator,
                        [SWGApiClient escape:key], [NSString stringWithFormat:@"%@", [values componentsJoinedByString:@","]]]];

                }
                else if([format isEqualToString:@"tsv"]) {
                    [requestUrl appendString:[NSString stringWithFormat:@"%@%@=%@", separator,
                        [SWGApiClient escape:key], [NSString stringWithFormat:@"%@", [values componentsJoinedByString:@"\t"]]]];

                }
                else if([format isEqualToString:@"pipes"]) {
                    [requestUrl appendString:[NSString stringWithFormat:@"%@%@=%@", separator,
                        [SWGApiClient escape:key], [NSString stringWithFormat:@"%@", [values componentsJoinedByString:@"|"]]]];

                }
                else if([format isEqualToString:@"multi"]) {
                    for(id obj in values) {
                        [requestUrl appendString:[NSString stringWithFormat:@"%@%@=%@", separator,
                            [SWGApiClient escape:key], [NSString stringWithFormat:@"%@", obj]]];
                        counter += 1;
                    }

                }
            }
            else {
                [requestUrl appendString:[NSString stringWithFormat:@"%@%@=%@", separator,
                                          [SWGApiClient escape:key], [NSString stringWithFormat:@"%@", [queryParams valueForKey:key]]]];
            }

            counter += 1;
        }
    }
    return requestUrl;
}

- (void) updateHeaderParams:(NSDictionary *__autoreleasing *)headers
                queryParams:(NSDictionary *__autoreleasing *)querys
           WithAuthSettings:(NSArray *)authSettings {

    if (!authSettings || [authSettings count] == 0) {
        return;
    }

    NSMutableDictionary *headersWithAuth = [NSMutableDictionary dictionaryWithDictionary:*headers];
    NSMutableDictionary *querysWithAuth = [NSMutableDictionary dictionaryWithDictionary:*querys];

    SWGConfiguration *config = [SWGConfiguration sharedConfig];
    for (NSString *auth in authSettings) {
        NSDictionary *authSetting = [[config authSettings] objectForKey:auth];

        if (authSetting) {
            if ([authSetting[@"in"] isEqualToString:@"header"]) {
                [headersWithAuth setObject:authSetting[@"value"] forKey:authSetting[@"key"]];
            }
            else if ([authSetting[@"in"] isEqualToString:@"query"]) {
                [querysWithAuth setObject:authSetting[@"value"] forKey:authSetting[@"key"]];
            }
        }
    }

    *headers = [NSDictionary dictionaryWithDictionary:headersWithAuth];
    *querys = [NSDictionary dictionaryWithDictionary:querysWithAuth];
}

-(NSNumber*)  executeWithPath: (NSString*) path
                       method: (NSString*) method
                  queryParams: (NSDictionary*) queryParams
                         body: (id) body
                 headerParams: (NSDictionary*) headerParams
                 authSettings: (NSArray *) authSettings
           requestContentType: (NSString*) requestContentType
          responseContentType: (NSString*) responseContentType
              completionBlock: (void (^)(id, NSError *))completionBlock {
    // setting response serializer
    if ([responseContentType isEqualToString:@"application/json"]) {
        self.responseSerializer = [AFJSONResponseSerializer serializer];
    }
    else {
        self.responseSerializer = [AFHTTPResponseSerializer serializer];
    }

    // auth setting
    [self updateHeaderParams:&headerParams queryParams:&queryParams WithAuthSettings:authSettings];

    NSMutableURLRequest * request = nil;
    if (body != nil && [body isKindOfClass:[NSArray class]]){
        SWGFile * file;
        NSMutableDictionary * params = [[NSMutableDictionary alloc] init];
        for(id obj in body) {
            if([obj isKindOfClass:[SWGFile class]]) {
                file = (SWGFile*) obj;
                requestContentType = @"multipart/form-data";
            }
            else if([obj isKindOfClass:[NSDictionary class]]) {
                for(NSString * key in obj) {
                    params[key] = obj[key];
                }
            }
        }
        NSString * urlString = [[NSURL URLWithString:path relativeToURL:self.baseURL] absoluteString];

        // request with multipart form
        if([requestContentType isEqualToString:@"multipart/form-data"]) {
            request = [self.requestSerializer multipartFormRequestWithMethod: @"POST"
                                                                   URLString: urlString
                                                                  parameters: nil
                                                   constructingBodyWithBlock: ^(id<AFMultipartFormData> formData) {

                                                       for(NSString * key in params) {
                                                           NSData* data = [params[key] dataUsingEncoding:NSUTF8StringEncoding];
                                                           [formData appendPartWithFormData: data name: key];
                                                       }

                                                       if (file) {
                                                           [formData appendPartWithFileData: [file data]
                                                                                       name: [file paramName]
                                                                                   fileName: [file name]
                                                                                   mimeType: [file mimeType]];
                                                       }

                                                   }
                                                                       error:nil];
        }
        // request with form parameters or json
        else {
            NSString* pathWithQueryParams = [self pathWithQueryParamsToString:path queryParams:queryParams];
            NSString* urlString = [[NSURL URLWithString:pathWithQueryParams relativeToURL:self.baseURL] absoluteString];

            request = [self.requestSerializer requestWithMethod:method
                                                      URLString:urlString
                                                     parameters:params
                                                          error:nil];
        }
    }
    else {
        NSString * pathWithQueryParams = [self pathWithQueryParamsToString:path queryParams:queryParams];
        NSString * urlString = [[NSURL URLWithString:pathWithQueryParams relativeToURL:self.baseURL] absoluteString];

        request = [self.requestSerializer requestWithMethod:method
                                                  URLString:urlString
                                                 parameters:body
                                                      error:nil];
    }

    for(NSString * key in [headerParams keyEnumerator]){
        [request setValue:[headerParams valueForKey:key] forHTTPHeaderField:key];
    }

    if([[request valueForHTTPHeaderField:@"Content-Encoding"] isEqualToString:@"gzip"]) {
        NSData *compBodyData = [GzipUtility gzipData:[request HTTPBody]];
        [request setHTTPBody:compBodyData];
    }

    NSNumber *requestId = [self _genNextRequestId];
    NSDate *requestStartDate = [NSDate date];

    __weak id weakSelf = self;

    AFHTTPRequestOperation *operation = \
    [self HTTPRequestOperationWithRequest:request
                                  success:^(AFHTTPRequestOperation *operation, id data) {
                                      if([weakSelf _finishRequestWithId:requestId]) {
                                          NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:requestStartDate];
                                          [weakSelf _logResponseWithId:requestId
                                                             operation:operation
                                                              duration:duration
                                                           decodedData:data
                                                                 error:nil];

                                          completionBlock(data, nil);
                                      }
                                  }
                                  failure:^(AFHTTPRequestOperation *operation, NSError *error) {

                                      if([weakSelf _finishRequestWithId:requestId]) {
                                          NSMutableDictionary *userInfo = [error.userInfo mutableCopy];

                                          if(operation.responseObject) {
                                              // Add in the (parsed) response body.
                                              userInfo[SWGResponseObjectErrorKey] = operation.responseObject;
                                          }
                                          NSError *augmentedError = [error initWithDomain:error.domain
                                                                                     code:error.code
                                                                                 userInfo:userInfo];

                                          NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:requestStartDate];
                                          [weakSelf _logResponseWithId:requestId
                                                             operation:operation
                                                              duration:duration
                                                           decodedData:nil
                                                                 error:augmentedError];

                                          completionBlock(nil, augmentedError);
                                      }
                                  }
     ];

    [self.operationQueue addOperation:operation];

    [self _queueRequestOperation:operation withId:requestId];

    return requestId;
}

- (void) cancelRequest:(NSNumber*)requestId {
    AFHTTPRequestOperation *operation = [self _finishRequestWithId:requestId];
    [operation cancel];
}

@end