// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ADTestLoader.h"
#import "ADTokenCacheItem.h"
#import "ADUserInformation.h"
#import "ADTestURLSession.h"
#import "ADTestURLResponse.h"

#define THROW_EXCEPTION_NOLINE(INFO, FMT, ...) @throw [NSException exceptionWithName:ADTestLoaderException reason:[NSString stringWithFormat:FMT, ##__VA_ARGS__] userInfo:INFO];

#define CHECK_THROW_EXCEPTION_NOLINE(CHECK, INFO, FMT, ...) if (!(CHECK)) { THROW_EXCEPTION_NOLINE(INFO, FMT, ##__VA_ARGS__ ) }

#define THROW_EXCEPTION(INFO, FMT, ...) @throw [NSException exceptionWithName:ADTestLoaderException reason:[NSString stringWithFormat:FMT " (%@:%ld)", ##__VA_ARGS__, _parserPath.lastPathComponent, (long)_parser.lineNumber] userInfo:INFO];

#define CHECK_THROW_EXCEPTION(CHECK, INFO, FMT, ...) if (!(CHECK)) { THROW_EXCEPTION(INFO, FMT, ##__VA_ARGS__ ) }

NSExceptionName ADTestLoaderException = @"ADTestLoaderException";
NSErrorDomain ADTestErrorDomain = @"ADTestErrorDomain";

typedef enum ADTestLoaderParserState
{
    // These two states are effectively identical, the parser moves to the "parsing" state after
    // finishing with a known element
    Started,
    Parsing,
    
    // The state creates a dictionary of the subsequent elements and values until it hits the end
    // tag, it will restore the parser in the provided endState
    DictionaryCapture,
    DictionaryCaptureJWT,
    
    // Currently parsing the Network element
    Network,
    NetworkRequestResponse,
    
    NetworkRequest,
    NetworkRequestBody,
    
    NetworkResponse,
    NetworkResponseBody,
    
    // Curently parsing the cache element
    Cache,
    CacheToken,
    CacheTokenContents,
    
    // Parser completed
    Finished,
} ADTestLoaderParserState;


// This is because -initWithBlock wasn't added to NSThread until macOS 10.12/iOS 10.
@interface ADTestLoaderBlockWrapper : NSObject

- (void)runBlock;

@end

@implementation ADTestLoaderBlockWrapper
{
    dispatch_block_t _block;
}


+ (instancetype)wrapperWithBlock:(void(^)(void))block
{
    ADTestLoaderBlockWrapper *wrapper = [ADTestLoaderBlockWrapper new];
    wrapper->_block = block;
    return wrapper;
}

- (void)runBlock
{
    _block();
}

@end

@interface ADTestLoader () <NSXMLParserDelegate>

@end

@implementation ADTestLoader
{
    NSString *_parseString;
    NSInputStream *_parseStream;
    
    NSXMLParser *_parser;
    NSString *_parserPath;
    NSMutableArray *_parserStack;
    NSMutableArray *_parserPathStack;
    
    NSUInteger _currentLevel;
    
    ADTestLoaderParserState _state;
    BOOL _captureText;
    
    // Dictionary Capture State
    NSMutableArray *_keyStack;
    NSMutableArray *_valueStack;
    
    NSString *_currentKey;
    NSMutableDictionary *_currentDict;
    NSMutableString *_currentValue;
    
    ADTestLoaderParserState _endCaptureState;
    
    // JWT Capture State
    NSMutableArray *_jwtParts;
    
    // Token Cache Capture
    ADTokenCacheItem *_currentCacheItem;
    
    // Network capture
    ADTestURLResponse *_currentRequest;
    NSMutableDictionary *_requestHeaders;
    
    NSMutableDictionary *_testVariables;
    NSMutableArray *_networkRequests;
    NSMutableArray *_cacheItems;
    
    NSRegularExpression *_substitutionRegex;
}

+ (ADTestVariables *)loadTest:(NSString *)testName
{
    NSURL *testDataPath = [NSURL URLWithString:[[NSBundle mainBundle] pathForResource:testName ofType:@"xml"]];
    NSAssert(testDataPath, @"Could not create test data path URL");
    return nil;
}

+ (NSString *)pathForFile:(NSString *)fileName
{
    NSString *resource = fileName.lastPathComponent.stringByDeletingPathExtension;
    NSString *extension = fileName.pathExtension;
    if ([NSString adIsStringNilOrBlank:extension])
    {
        extension = @"xml";
    }
    
    return [[NSBundle bundleForClass:[self class]] pathForResource:resource ofType:extension];
}

- (id)init
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    NSError *error = nil;
    _substitutionRegex = [NSRegularExpression regularExpressionWithPattern:@"\\$\\(([a-zA-Z0-9_-]+)\\)" options:0 error:&error];
    CHECK_THROW_EXCEPTION_NOLINE(_substitutionRegex, @{ @"error" : error }, @"Failed to create substitution regex");
    
    return self;
}

- (id)initWithFile:(NSString *)file
{
    CHECK_THROW_EXCEPTION_NOLINE(file, nil, @"File must be specified");
    if (!file)
    {
        return nil;
    }
    
    NSString *filePath = [[self class] pathForFile:file];
    CHECK_THROW_EXCEPTION_NOLINE(filePath, @{ @"file" : file }, @"Could not find file \"%@\" in bundle.", file);
    
    if (!(self = [self initWithContentsOfPath:filePath]))
    {
        THROW_EXCEPTION_NOLINE(nil, @"Unable to instantiate parser");
        return nil;
    }
    
    return self;
}

- (id)initWithString:(NSString *)string
{
    if (!(self = [self init]))
    {
        return nil;
    }
    
    _parseString = string;
    _parserPath = @"string";
    
    return self;
}

- (id)initWithContentsOfPath:(NSString *)path
{
    if (!(self = [self init]))
    {
        return nil;
    }
    
    _parseStream = [NSInputStream inputStreamWithFileAtPath:path];
    _parserPath = path;
    
    return self;
}

- (BOOL)parse:(NSError * __autoreleasing *)error
{
    __block BOOL ret = NO;
    // NSXMLParser is one of the few (only?) ObjC APIs that use exceptions, so to safely use this
    // parser we have to wrap the parser call in a try/catch block, and marshal out the exception as
    // an error.
    
    __block NSError *parseError = nil;
    __block dispatch_semaphore_t dsem = dispatch_semaphore_create(0);
    
    // On top of being one of the few ObjC APIs that use exceptions, it's also "non-reentrant", which
    // doesn't really mean "non-reentrant" it means "we use a ton of thread local storage, so if you
    // run multiple NSXMLParser instances on the same thread, even though they aren't actually re-
    // entrant on each other, they will conflict with each other, so we throw an exception if we see
    // any state laying around. Oh, and we aren't always the greatest at cleaning up after ourselves
    // either so sometimes your thread might just end up in a hosed state where even though you've
    // already released all of your NSXMLParsers, you can't spin up another!
    //
    // Long story short, the only safe way to use this API is to spin up a new thread (note, thread,
    // not dispatch queue, because dispatch queues can reuse threads under the hood) so that way
    // we know that we're getting clean thread every time.
    ADTestLoaderBlockWrapper *wrapper = [ADTestLoaderBlockWrapper wrapperWithBlock:^{
        _state = Started;
        _parserStack = [NSMutableArray new];
        _parserPathStack = [NSMutableArray new];
        
        if (_parseStream)
        {
            _parser = [[NSXMLParser alloc] initWithStream:_parseStream];
            _parseStream = nil;
        }
        else
        {
            _parser = [[NSXMLParser alloc] initWithData:[_parseString dataUsingEncoding:NSUTF8StringEncoding]];
            _parseString = nil;
        }
        _parser.delegate = self;
        
        @try
        {
            ret = [_parser parse];
            if (ret == NO && error)
            {
                parseError = _parser.parserError;
                
                _testVariables = nil;
                _cacheItems = nil;
                _networkRequests = nil;
            }
        }
        @catch (NSException *exception)
        {
            _testVariables = nil;
            _cacheItems = nil;
            _networkRequests = nil;
            
            parseError = [NSError errorWithDomain:ADTestErrorDomain code:-1 userInfo:@{ @"exception" : exception }];
            
            ret = NO;
        }
        @finally
        {
            _parser.delegate = nil;
            _parser = nil;
            _parserPath = nil;
            _parserPathStack = nil;
            _parserStack = nil;
            
            dispatch_semaphore_signal(dsem);
        }
    }];
    NSThread *parserThread = [[NSThread alloc] initWithTarget:wrapper selector:@selector(runBlock) object:nil];
    [parserThread start];
    dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER);
    
    
    if (error)
    {
        *error = parseError;
    }
    
    return ret;
}

- (NSString *)valueForMatch:(NSTextCheckingResult *)match
                      input:(NSString *)input
{
    NSString *key = [input substringWithRange:[match rangeAtIndex:1]];
    NSString *value = _testVariables[key];
    CHECK_THROW_EXCEPTION(value, nil, @"Substitution value \"%@\" not defined", value);
    
    return value;
}

- (NSString *)replaceInlinedVariables:(NSString *)input
{
    if (!input)
    {
        return nil;
    }
    
    NSUInteger cInput = input.length;
    NSArray<NSTextCheckingResult *> *matches = [_substitutionRegex matchesInString:input options:0 range:NSMakeRange(0, cInput)];
    if (matches.count == 0)
        return [input copy];
    
    // Early exit case for when the input string is solely a substitute variable
    if (matches.count == 1 && matches[0].range.length == cInput)
    {
        return [self valueForMatch:matches[0] input:input];
    }
    
    NSMutableString *output = [NSMutableString new];
    NSUInteger currPosition = 0;
    for (NSTextCheckingResult *result in matches)
    {
        NSRange resultRange = result.range;
        if (resultRange.location > currPosition)
        {
            [output appendString:[input substringWithRange:NSMakeRange(currPosition, resultRange.location - currPosition)]];
            currPosition += resultRange.location;
        }
        
        [output appendString:[self valueForMatch:result input:input]];
        currPosition += resultRange.length;
    }
    
    return [output copy];
}

#pragma mark -
#pragma mark NSXMLParserDelegate

// sent when the parser begins parsing of the document.
- (void)parserDidStartDocument:(NSXMLParser *)parser
{
    (void)parser;
}

// sent when the parser has completed parsing. If this is encountered, the parse was successful.
- (void)parserDidEndDocument:(NSXMLParser *)parser
{
    (void)parser;
    
    if (_parserStack.count == 0)
    {
        _state = Finished;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    (void)parser;
    if (!_captureText)
    {
        return;
    }
    
    NSString *trimmedString = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!_currentValue)
    {
        _currentValue = [trimmedString mutableCopy];
    }
    else
    {
        [_currentValue appendString:trimmedString];
    }
}

- (void)startElement:(NSString *)elementName namespaceURI:(nullable NSString *)namespaceURI qualifiedName:(nullable NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)namespaceURI;
    (void)qName;
    
    if ([elementName isEqualToString:@"testvariables"])
    {
        [self startTestVariables:attributeDict];
        return;
    }
    
    if ([elementName isEqualToString:@"network"])
    {
        _state = Network;
        [self startNetwork:attributeDict];
        return;
    }
    else if ([elementName isEqualToString:@"cache"])
    {
        _state = Cache;
        [self startCache:attributeDict];
        return;
    }
    else
    {
        THROW_EXCEPTION(nil, @"Do not recogonized element \"%@\"", elementName);
    }
}

// sent when the parser finds an element start tag.
// In the case of the cvslog tag, the following is what the delegate receives:
//   elementName == cvslog, namespaceURI == http://xml.apple.com/cvslog, qualifiedName == cvslog
// In the case of the radar tag, the following is what's passed in:
//    elementName == radar, namespaceURI == http://xml.apple.com/radar, qualifiedName == radar:radar
// If namespace processing >isn't< on, the xmlns:radar="http://xml.apple.com/radar" is returned as an attribute pair, the elementName is 'radar:radar' and there is no qualifiedName.

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(nullable NSString *)namespaceURI qualifiedName:(nullable NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)parser;
    
    elementName = elementName.lowercaseString;
    
    // Include elements are special...
    if ([elementName isEqualToString:@"include"])
    {
        NSString *file = attributeDict[@"file"];
        CHECK_THROW_EXCEPTION(file, nil, @"File not specified in include tag.");
        
        NSString *filePath = [[self class] pathForFile:file];
        CHECK_THROW_EXCEPTION(filePath, @{ @"file" : file }, @"Unable to find file %@", file);
        
        __block NSException *thrownException = nil;
        __block dispatch_semaphore_t dsem = dispatch_semaphore_create(0);
        // See the comment in -parse about why we have to do this thread wrapping nonsense.
        ADTestLoaderBlockWrapper *wrapper = [ADTestLoaderBlockWrapper wrapperWithBlock:^{
            [_parserStack addObject:_parser];
            [_parserPathStack addObject:_parserPath];
            
            _parser = [[NSXMLParser alloc] initWithStream:[NSInputStream inputStreamWithFileAtPath:filePath]];
            _parser.delegate = self;
            _parserPath = filePath;
            
            @try
            {
                [_parser parse];
            }
            @catch (NSException *exception)
            {
                thrownException = exception;
            }
            @finally
            {
                _parser.delegate = nil;
                _parser = _parserStack.lastObject;
                [_parserStack removeLastObject];
                
                _parserPath = _parserPathStack.lastObject;
                [_parserPathStack removeLastObject];
                
                dispatch_semaphore_signal(dsem);
            }
        }];
        NSThread *parserThread = [[NSThread alloc] initWithTarget:wrapper selector:@selector(runBlock) object:nil];
        [parserThread start];
        dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER);
        
        if (thrownException)
        {
            @throw thrownException;
        }
        
        return;
    }
    
    switch (_state)
    {
        case Started:
        case Parsing:
            [self startElement:elementName namespaceURI:namespaceURI qualifiedName:qName attributes:attributeDict];
            return;
        case DictionaryCapture:
            [self startCaptureElement:elementName attributes:attributeDict];
            return;
        case DictionaryCaptureJWT:
            [self startJwtPart:elementName attributes:attributeDict];
            return;
        case Network:
            THROW_EXCEPTION(nil, @"Invalid document, network unexpected here.");
        case NetworkRequestResponse:
            [self startRequestResponse:elementName attributes:attributeDict];
            return;
        case NetworkRequest:
            [self parseRequest:elementName attributes:attributeDict];
            return;
        case NetworkRequestBody:
        case NetworkResponseBody:
            THROW_EXCEPTION(nil, @"No xml elements supported within a <body> tag.");
        case NetworkResponse:
            [self parseResponse:elementName attributes:attributeDict];
            return;
        case Cache:
            [self startToken:elementName attributes:attributeDict];
            return;
        case CacheToken:
            [self startTokenContents:elementName attributes:attributeDict];
            return;
        case CacheTokenContents:
            THROW_EXCEPTION(nil, @"can not have sub-sub elements in cache tokens");
        case Finished:
            THROW_EXCEPTION(nil, @"Parser encountered element after finished parsing.");
    }
}

// sent when an end tag is encountered. The various parameters are supplied as above.
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(nullable NSString *)namespaceURI qualifiedName:(nullable NSString *)qName
{
    (void)parser;
    (void)namespaceURI;
    (void)qName;
    
    elementName = elementName.lowercaseString;
    
    if ([elementName isEqualToString:@"include"])
    {
        return;
    }
    
    switch (_state)
    {
        case Started:
        case Parsing:
            THROW_EXCEPTION(nil, @"End element before start element.");
            return;
        case DictionaryCapture:
            [self endCaptureElement:elementName];
            return;
        case DictionaryCaptureJWT:
            [self endJwt:elementName];
            return;
        case Network:
            // The "Network" state jumps immediately into NetworkRequestResponse once it gets a
            // request or response tag, and will go back to that.
            THROW_EXCEPTION(nil, @"Network state should only be hit at the beginning of an element.");
        case NetworkRequestResponse:
            [self endNetwork:elementName];
            return;
        case NetworkRequest:
            [self endRequest:elementName];
            return;
        case NetworkRequestBody:
            [self endRequestBody:elementName];
            return;
        case NetworkResponseBody:
            [self endResponseBody:elementName];
            return;
        case NetworkResponse:
            [self endResponse:elementName];
            return;
        case Cache:
            [self endCache:elementName];
            return;
        case CacheToken:
            [self endToken:elementName];
            return;
        case CacheTokenContents:
            [self endTokenContents:elementName];
            return;
        case Finished:
            THROW_EXCEPTION(nil, @"Parser encountered element after finished parsing.");
    }
}

#pragma mark -
#pragma mark Dictionary Capturing

- (void)startDictionaryCapture:(NSMutableDictionary *)dictionary
                   startingKey:(NSString *)startingKey
                      endState:(ADTestLoaderParserState)endState
{
    _keyStack = [NSMutableArray new];
    _valueStack = [NSMutableArray new];
    _currentDict = dictionary;
    _currentKey = startingKey;
    _endCaptureState = endState;
    _state = DictionaryCapture;
}

- (void)startCaptureElement:(NSString *)name
                 attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    _captureText = YES;
    [_keyStack addObject:_currentKey];
    if (!_currentDict)
    {
        _currentDict = [NSMutableDictionary new];
        [_valueStack.lastObject setValue:_currentDict forKey:_currentKey];
    }
    [_valueStack addObject:_currentDict];
    _currentDict = nil;
    _currentKey = name;
    
    NSString *type = attributeDict[@"type"];
    if ([type isEqualToString:@"jwt"])
    {
        _state = DictionaryCaptureJWT;
        _jwtParts = [NSMutableArray new];
    }
}

- (BOOL)endCaptureElement:(NSString *)name
{
    NSAssert([name isEqualToString:_currentKey], @"mismatched end tag");
    _captureText = NO;
    
    NSMutableDictionary *parentDict = _valueStack.lastObject;
    if (!parentDict)
    {
        _state = _endCaptureState;
        _keyStack = nil;
        _valueStack = nil;
        _currentDict = nil;
        return NO;
    }
    
    if (_currentValue.length > 0)
    {
        [parentDict setValue:[self replaceInlinedVariables:_currentValue] forKey:name];
        [_currentValue setString:@""];
    }
    
    _currentKey = [_keyStack lastObject];
    [_keyStack removeLastObject];
    
    _currentDict = parentDict;
    [_valueStack removeLastObject];
    
    return YES;
}


#pragma mark JWT

- (void)startJwtPart:(NSString *)elementName
          attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    
    CHECK_THROW_EXCEPTION([elementName isEqualToString:@"part"], nil, @"Unsupported element type \"%@\", only \"part\" is supporting in JWT parsing.", elementName);
}

- (void)endJwt:(NSString *)elementName
{
    if ([elementName isEqualToString:@"part"])
    {
        // Round trip through the JSON parser to ensure valid JSON and remove extraneous whitespace
        NSError *error = nil;
        id jsonObject =
        [NSJSONSerialization JSONObjectWithData:[_currentValue dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
        
        CHECK_THROW_EXCEPTION(jsonObject, @{ @"error" : error }, @"Unable to parse JSON object in JWT.");
        
        NSString *base64Json =
        [NSString adBase64EncodeData:[NSJSONSerialization dataWithJSONObject:jsonObject options:0 error:&error]];
        CHECK_THROW_EXCEPTION(base64Json, @{ @"error" : error }, @"Unable to serialize object back to json string");
        
        [_jwtParts addObject:base64Json];
        [_currentValue setString:@""];
    }
    else if ([elementName isEqualToString:_currentKey])
    {
        NSString *format = @"%@";
        for (NSString *part in _jwtParts)
        {
            [_currentValue appendFormat:format, part];
            format = @".%@";
        }
        
        [self endCaptureElement:elementName];
        _state = DictionaryCapture;
    }
}

#pragma mark -
#pragma mark Test Variables

- (void)startTestVariables:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    
    CHECK_THROW_EXCEPTION(!_testVariables, nil, @"Multiple TestVariables dictionaries in test file");
    
    _testVariables = [NSMutableDictionary new];
    [self startDictionaryCapture:_testVariables startingKey:@"testvariables" endState:Parsing];
}

#pragma mark -
#pragma mark Network

- (void)startNetwork:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    
    CHECK_THROW_EXCEPTION(!_networkRequests, nil, @"<Network> should only appear once in the load out file.");
    _networkRequests = [NSMutableArray new];
    
    _state = NetworkRequestResponse;
}

- (void)startRequestResponse:(NSString *)elementName
                  attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    
    if ([elementName isEqualToString:@"request"])
    {
        [self startRequest:attributeDict];
    }
    else if ([elementName isEqualToString:@"response"])
    {
        [self startResponse:attributeDict];
    }
    else
    {
        THROW_EXCEPTION(nil, @"Unsupported element type \"%@\" in network section", elementName);
    }
}

#pragma mark Network Requests

- (void)startRequest:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    _state = NetworkRequest;
    
    CHECK_THROW_EXCEPTION(!_currentRequest, nil, @"New request without a matching response! A <response> element must come after a request element.");
    
    NSString *urlString = attributeDict[@"url"];
    CHECK_THROW_EXCEPTION(urlString, nil, @"Request element is required to have a url attribute.");
    
    NSURL *url = [NSURL URLWithString:urlString];
    CHECK_THROW_EXCEPTION(url, nil, @"Provided request url \"%@\" is not a valid URL.", urlString);
    
    _currentRequest = [[ADTestURLResponse alloc] init];
    _currentRequest.requestURL = url;
}

- (void)parseRequest:(NSString *)elementName
          attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)elementName;
    (void)attributeDict;
    if ([elementName isEqualToString:@"headers"])
    {
        CHECK_THROW_EXCEPTION(!_requestHeaders, nil, @"Only one headers section allowed per request.");
        _requestHeaders = [NSMutableDictionary new];
        [self startDictionaryCapture:_requestHeaders startingKey:@"headers" endState:NetworkRequest];
        return;
    }
    else if ([elementName isEqualToString:@"body"])
    {
        [self startRequestBody:attributeDict];
    }
}

- (void)startRequestBody:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    _state = NetworkRequestBody;
    _captureText = YES;
}

- (void)endRequestBody:(NSString *)elementName
{
    (void)elementName;
    _currentRequest.requestBody = [_currentValue dataUsingEncoding:NSUTF8StringEncoding];
    [_currentValue setString:@""];
    _state = NetworkRequest;
    _captureText = NO;
}

- (void)endRequest:(NSString *)elementName
{
    (void)elementName;
    _currentRequest.requestHeaders = _requestHeaders;
    _requestHeaders = nil;
    _state = NetworkRequestResponse;
}

#pragma mark Network Responses

- (void)startResponse:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    CHECK_THROW_EXCEPTION(_currentRequest, nil, @"An <request> element must appear before a respo;nse element.");
    _state = NetworkResponse;
    
    NSString *code = attributeDict[@"code"];
    NSString *error = attributeDict[@"error"];
    CHECK_THROW_EXCEPTION(code || error, nil, @"Either \"code\" or \"error\" attribute must be provided on a network response.");
    
    NSString *urlString = attributeDict[@"url"];
    NSURL *url = nil;
    if (urlString)
    {
        url = [NSURL URLWithString:urlString];
        CHECK_THROW_EXCEPTION(url, nil, @"Provided request url \"%@\" is not a valid URL.", urlString);
    }
    else
    {
        url = _currentRequest->_requestURL;
    }
    
    NSHTTPURLResponse *response =
    [[NSHTTPURLResponse alloc] initWithURL:url
                                statusCode:code.integerValue
                               HTTPVersion:nil
                              headerFields:nil];
    _currentRequest->_response = response;
}

- (void)parseResponse:(NSString *)elementName
           attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    if ([elementName isEqualToString:@"body"])
    {
        [self startResponseBody:attributeDict];
        return;
    }
    
    THROW_EXCEPTION(nil, @"Unrecognized element type \"%@\" in network response", elementName);
}

- (void)startResponseBody:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    _state = NetworkResponseBody;
    _captureText = YES;
}

- (void)endResponseBody:(NSString *)elementName
{
    (void)elementName;
    _currentRequest.responseData = [_currentValue dataUsingEncoding:NSUTF8StringEncoding];
    [_currentValue setString:@""];
    _state = NetworkResponse;
    _captureText = NO;
}

- (void)endResponse:(NSString *)elementName
{
    (void)elementName;
    
    [_networkRequests addObject:_currentRequest];
    _currentRequest = nil;
    _state = NetworkRequestResponse;
}

- (void)endNetwork:(NSString *)elementName
{
    (void)elementName;
    
    _state = Parsing;
}

#pragma mark -
#pragma mark Cache

typedef enum ADALTokenType
{
    AccessToken,
    RefreshToken,
    MultiResourceRefreshToken,
    FamilyRefreshToken,
} ADALTokenType;

- (void)startCache:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)attributeDict;
    _cacheItems = [NSMutableArray new];
}

- (void)startToken:(NSString *)elementName
        attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    ADALTokenType type;
    
    if ([elementName isEqualToString:@"accesstoken"])
    {
        type = AccessToken;
    }
    else if ([elementName isEqualToString:@"refreshtoken"])
    {
        type = RefreshToken;
    }
    else if ([elementName isEqualToString:@"multiresourcerefreshtoken"])
    {
        type = MultiResourceRefreshToken;
    }
    else if ([elementName isEqualToString:@"familyrefreshtoken"])
    {
        type = FamilyRefreshToken;
    }
    else
    {
        THROW_EXCEPTION(nil, @"Unrecognized element type \"%@\" in Cache section.", elementName);
    }
    
    NSString *authority = [self replaceInlinedVariables:attributeDict[@"authority"]];
    CHECK_THROW_EXCEPTION(authority, nil, @"authority missing from %@", elementName);
    NSURL *authorityUrl = [NSURL URLWithString:authority];
    CHECK_THROW_EXCEPTION(authorityUrl, nil, @"authority \"%@\" is not a valid URL!", authority);
    
    // Not used in ObjC for legacy reasons, but required for document spec
    NSString *tenant = [self replaceInlinedVariables:attributeDict[@"tenant"]];
    CHECK_THROW_EXCEPTION(tenant, nil, @"tenant missing from %@", elementName);
    
    NSString *token = [self replaceInlinedVariables:attributeDict[@"token"]];
    CHECK_THROW_EXCEPTION(token, nil, @"token missing from %@", elementName);
    
    NSString *resource = [self replaceInlinedVariables:attributeDict[@"resource"]];
    switch (type)
    {
        case AccessToken:
        case RefreshToken:
            CHECK_THROW_EXCEPTION(resource, nil, @"resource is missing from %@", elementName);
            break;
        case MultiResourceRefreshToken:
        case FamilyRefreshToken:
            CHECK_THROW_EXCEPTION(!resource, nil, @"resource is invalid on %@", elementName);
        default:
            break;
    }
    
    NSString *clientId = [self replaceInlinedVariables:attributeDict[@"clientId"]];
    switch (type)
    {
        case AccessToken:
        case RefreshToken:
        case MultiResourceRefreshToken:
            CHECK_THROW_EXCEPTION(clientId, nil, @"clientId is missing from %@", elementName);
            break;
            
        case FamilyRefreshToken:
            CHECK_THROW_EXCEPTION(!clientId, nil, @"clientId is invalid on %@", elementName);
        default:
            break;
    }
    
    NSString *expiresIn = [self replaceInlinedVariables:attributeDict[@"expiresIn"]];
    NSDate *expiresOn = nil;
    switch (type)
    {
        case AccessToken:
        {
            int expiresInt = 3600;
            if (expiresIn)
            {
                NSScanner *scanner = [NSScanner scannerWithString:expiresIn];
                CHECK_THROW_EXCEPTION([scanner scanInt:&expiresInt], nil, @"expiresIn value \"%@\" is not a valid integer", expiresIn);
            }
            expiresOn = [NSDate dateWithTimeIntervalSinceNow:(NSTimeInterval)expiresInt];
            break;
        }
        case RefreshToken:
        case MultiResourceRefreshToken:
        case FamilyRefreshToken:
            CHECK_THROW_EXCEPTION(!expiresIn, nil, @"expiresIn is invalid on %@", elementName);
        default:
            break;
    }
    
    NSString *familyId = [self replaceInlinedVariables:attributeDict[@"familyId"]];
    switch (type)
    {
        case AccessToken:
        case RefreshToken:
            CHECK_THROW_EXCEPTION(!familyId, nil, @"familyId is invalid on %@", elementName);
            break;
        case FamilyRefreshToken:
            CHECK_THROW_EXCEPTION(familyId, nil, @"familyId is missing from %@", elementName);
            clientId = [NSString stringWithFormat:@"foci-%@", familyId];
        default:
            break;
    }
    
    NSString *idToken = [self replaceInlinedVariables:attributeDict[@"idToken"]];
    
    _currentCacheItem = [ADTokenCacheItem new];
    _currentCacheItem.authority = authority;
    _currentCacheItem.resource = resource;
    _currentCacheItem.clientId = clientId;
    _currentCacheItem.familyId = familyId;
    _currentCacheItem.expiresOn = expiresOn;
    
    if (idToken)
    {
        ADAuthenticationError *error = nil;
        _currentCacheItem.userInformation = [ADUserInformation userInformationWithIdToken:idToken error:&error];
        CHECK_THROW_EXCEPTION(_currentCacheItem.userInformation, @{ @"error" : error }, @"Failed to parse idtoken \"%@\"", idToken);
    }
    
    switch (type)
    {
        case AccessToken:
            _currentCacheItem.accessToken = token;
            break;
        case RefreshToken:
        case MultiResourceRefreshToken:
        case FamilyRefreshToken:
            _currentCacheItem.refreshToken = token;
    }
    
    _state = CacheToken;
}

- (void)startTokenContents:(NSString *)elementName
                attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    (void)elementName;
    (void)attributeDict;
    CHECK_THROW_EXCEPTION(_state == CacheToken, nil, @"Parser in unexpected state");
    
    _state = CacheTokenContents;
}

- (void)endTokenContents:(NSString *)elementName
{
    (void)elementName;
    
    _state = CacheToken;
}

- (void)endToken:(NSString *)elementName
{
    (void)elementName;
    
    [_cacheItems addObject:_currentCacheItem];
    _currentCacheItem = nil;
    _state = Cache;
}

- (void)endCache:(NSString *)elementName
{
    (void)elementName;
    
    _state = Parsing;
}

@end