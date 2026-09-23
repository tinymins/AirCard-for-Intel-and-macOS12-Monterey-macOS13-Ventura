#import "../Sources/os_trace.h"
#include <assert.h>

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger offset;
    NSUInteger chunkSize;
} MemoryStream;

static long Receive(void *context, void *bytes, long length) {
    MemoryStream *stream = context;
    NSUInteger count = MIN((NSUInteger)length, stream->length - stream->offset);
    count = MIN(count, stream->chunkSize);
    memcpy(bytes, stream->bytes + stream->offset, count);
    stream->offset += count;
    return (long)count;
}

static void WriteUInt32(NSMutableData *data, NSUInteger offset, uint32_t value) {
    uint8_t bytes[] = {value & 0xFF, (value >> 8) & 0xFF,
                      (value >> 16) & 0xFF, (value >> 24) & 0xFF};
    [data replaceBytesInRange:NSMakeRange(offset, 4) withBytes:bytes];
}

static NSMutableData *LogRecord(void) {
    // Synthetic Info-level resource lookup, matching the iOS 18 message shape.
    // No identifiers or personal logs from a device are used in this fixture.
    NSData *process = [@"/usr/libexec/passd\0" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *image = [@"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation\0"
                       dataUsingEncoding:NSUTF8StringEncoding];
    NSData *message = [@"Resource lookup\n\tResult        : file:///var/mobile/Library/Passes/Cards/AAAAAAAAAAAAAAAAAAAAAAAAAAA=.pkpass/en.lproj/actions.strings\0"
                         dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *record = [NSMutableData dataWithLength:129];
    uint8_t *header = record.mutableBytes;
    header[0] = 2;
    header[1] = 8;
    header[5] = 129;
    header[37] = (uint8_t)process.length;
    header[68] = 1; // Info
    header[107] = (uint8_t)image.length;
    WriteUInt32(record, 109, (uint32_t)message.length);
    [record appendData:process];
    [record appendData:image];
    [record appendData:message];
    return record;
}

static NSData *Frame(uint8_t type, NSData *payload) {
    uint32_t length = (uint32_t)payload.length;
    uint8_t header[] = {type, length & 0xFF, (length >> 8) & 0xFF,
                        (length >> 16) & 0xFF, (length >> 24) & 0xFF};
    if (type == 1) {
        header[1] = (length >> 24) & 0xFF;
        header[2] = (length >> 16) & 0xFF;
        header[3] = (length >> 8) & 0xFF;
        header[4] = length & 0xFF;
    }
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:5];
    [frame appendData:payload];
    return frame;
}

static void TestFrames(void) {
    NSData *ack = [NSPropertyListSerialization dataWithPropertyList:
        @{@"Status": @"RequestSuccessful"} format:NSPropertyListBinaryFormat_v1_0
        options:0 error:NULL];
    NSData *record = LogRecord();
    NSMutableData *wire = [Frame(1, ack) mutableCopy];
    [wire appendData:Frame(2, record)];
    // Both packets coalesced in one read, or fragmented inside every field.
    for (NSNumber *chunk in @[@1, @3, @65536]) {
        MemoryStream stream = {wire.bytes, wire.length, 0, chunk.unsignedIntegerValue};
        NSString *error = nil;
        uint8_t type = 0;
        NSData *reply = AirCardTraceReadFrame(Receive, &stream, &type, &error);
        assert(type == 1 && [reply isEqual:ack] && !error);
        NSData *event = AirCardTraceReadFrame(Receive, &stream, &type, &error);
        assert(type == 2 && [event isEqual:record] && !error);
        assert(AirCardTraceReadFrame(Receive, &stream, &type, &error) == nil);
        assert(error != nil);
    }
}

static void TestInvalidFrames(void) {
    const uint8_t invalidType[] = {3, 1, 0, 0, 0};
    const uint8_t oversized[] = {2, 0xFF, 0xFF, 0xFF, 0x7F};
    const uint8_t empty[] = {2, 0, 0, 0, 0};
    for (NSData *wire in @[
        [NSData dataWithBytes:invalidType length:5],
        [NSData dataWithBytes:oversized length:5],
        [NSData dataWithBytes:empty length:5],
        [NSData dataWithBytes:empty length:3],
        [Frame(2, LogRecord()) subdataWithRange:NSMakeRange(0, 10)],
    ]) {
        MemoryStream stream = {wire.bytes, wire.length, 0, 2};
        NSString *error = nil;
        uint8_t type = 0;
        assert(AirCardTraceReadFrame(Receive, &stream, &type, &error) == nil);
        assert(error != nil);
    }
}

static void TestRecords(void) {
    NSData *record = LogRecord();
    NSString *line = AirCardTraceLogLine(record);
    assert([line hasPrefix:@"passd(CoreFoundation): Resource lookup\n"]);
    assert([line containsString:@"/Cards/AAAAAAAAAAAAAAAAAAAAAAAAAAA=.pkpass/"]);
    assert([line hasSuffix:@"actions.strings\n"]);
    assert([line rangeOfString:@"\0"].location == NSNotFound);
    assert(AirCardTraceLogLine([record subdataWithRange:NSMakeRange(0, 128)]) == nil);
    assert(AirCardTraceLogLine([record subdataWithRange:NSMakeRange(0, record.length - 1)]) == nil);

    for (NSNumber *offset in @[@5, @109]) {
        NSMutableData *corrupt = [record mutableCopy];
        WriteUInt32(corrupt, offset.unsignedIntegerValue, UINT32_MAX);
        assert(AirCardTraceLogLine(corrupt) == nil);
    }
    NSMutableData *corrupt = [record mutableCopy];
    ((uint8_t *)corrupt.mutableBytes)[0] = 1;
    assert(AirCardTraceLogLine(corrupt) == nil);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--fixture") == 0) {
            fputs(AirCardTraceLogLine(LogRecord()).UTF8String, stdout);
            return 0;
        }
        TestFrames();
        TestInvalidFrames();
        TestRecords();
        puts("Log framing, fragmentation, multiline paths and malformed records passed.");
    }
    return 0;
}
