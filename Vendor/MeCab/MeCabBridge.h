#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMLLMeCabToken : NSObject

@property(nonatomic, readonly) NSUInteger utf8Location;
@property(nonatomic, readonly) NSUInteger utf8Length;
@property(nonatomic, copy, readonly) NSString *surface;
@property(nonatomic, copy, readonly) NSString *reading;

- (instancetype)initWithUTF8Location:(NSUInteger)utf8Location
                           utf8Length:(NSUInteger)utf8Length
                              surface:(NSString *)surface
                              reading:(NSString *)reading NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface AMLLMeCabBridge : NSObject {
@private
    void *_mecab;
}

- (nullable instancetype)initWithDictionaryPath:(NSString *)path
                                           error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSArray<AMLLMeCabToken *> *)tokensForText:(NSString *)text
                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
