#import "MeCabBridge.h"

#include <mecab.h>
#include <string>

static NSString *const AMLLMeCabErrorDomain = @"com.sirin.AMLLNowPlaying.MeCab";

@implementation AMLLMeCabToken

- (instancetype)initWithUTF8Location:(NSUInteger)utf8Location
                           utf8Length:(NSUInteger)utf8Length
                              surface:(NSString *)surface
                              reading:(NSString *)reading {
    self = [super init];
    if (self) {
        _utf8Location = utf8Location;
        _utf8Length = utf8Length;
        _surface = [surface copy];
        _reading = [reading copy];
    }
    return self;
}

@end

@implementation AMLLMeCabBridge

- (nullable instancetype)initWithDictionaryPath:(NSString *)path
                                           error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    const char *arguments[] = {
        "sirin-al-player",
        "--rcfile=/dev/null",
        "--dicdir",
        path.fileSystemRepresentation,
    };
    mecab_t *mecab = mecab_new(4, const_cast<char **>(arguments));
    if (mecab == nullptr) {
        if (error != nullptr) {
            NSString *message = [NSString stringWithUTF8String:mecab_strerror(nullptr)]
                ?: @"Unable to initialize MeCab";
            *error = [NSError errorWithDomain:AMLLMeCabErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return nil;
    }
    _mecab = mecab;
    return self;
}

- (void)dealloc {
    if (_mecab != nullptr) {
        mecab_destroy(static_cast<mecab_t *>(_mecab));
        _mecab = nullptr;
    }
}

- (nullable NSArray<AMLLMeCabToken *> *)tokensForText:(NSString *)text
                                                error:(NSError **)error {
    if (_mecab == nullptr || text.length == 0) {
        return @[];
    }

    std::string utf8(text.UTF8String ?: "");
    const mecab_node_t *node = mecab_sparse_tonode(
        static_cast<mecab_t *>(_mecab),
        utf8.c_str()
    );
    if (node == nullptr) {
        if (error != nullptr) {
            NSString *message = [NSString stringWithUTF8String:mecab_strerror(
                static_cast<mecab_t *>(_mecab)
            )] ?: @"MeCab failed to parse text";
            *error = [NSError errorWithDomain:AMLLMeCabErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return nil;
    }

    NSMutableArray<AMLLMeCabToken *> *tokens = [NSMutableArray array];
    NSUInteger consumedBytes = 0;
    for (const mecab_node_t *current = node; current != nullptr; current = current->next) {
        if (current->stat == MECAB_BOS_NODE || current->stat == MECAB_EOS_NODE) {
            continue;
        }

        NSUInteger rawLength = current->rlength;
        NSUInteger surfaceLength = current->length;
        NSUInteger leadingLength = rawLength >= surfaceLength ? rawLength - surfaceLength : 0;
        NSUInteger location = consumedBytes + leadingLength;
        consumedBytes += rawLength;
        if (location + surfaceLength > utf8.size()) {
            continue;
        }

        NSString *surface = [[NSString alloc] initWithBytes:current->surface
                                                     length:surfaceLength
                                                   encoding:NSUTF8StringEncoding];
        NSString *feature = current->feature == nullptr
            ? @""
            : [NSString stringWithUTF8String:current->feature];
        NSArray<NSString *> *fields = [feature componentsSeparatedByString:@","];
        NSString *reading = fields.count > 7 ? fields[7] : @"";
        if (surface == nil || reading.length == 0 || [reading isEqualToString:@"*"]) {
            continue;
        }

        [tokens addObject:[[AMLLMeCabToken alloc]
            initWithUTF8Location:location
                      utf8Length:surfaceLength
                         surface:surface
                         reading:reading]];
    }
    return tokens;
}

@end
