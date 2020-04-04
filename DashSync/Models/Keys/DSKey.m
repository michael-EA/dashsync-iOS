//
//  DSKey.m
//  DashSync
//
//  Created by Sam Westrich on 2/14/19.
//

#import "DSKey.h"
#import "NSString+Dash.h"
#import "NSData+Dash.h"
#import "NSString+Bitcoin.h"
#import "NSData+Bitcoin.h"
#import "NSMutableData+Dash.h"
#import "DSChain.h"
#import "DSBLSKey.h"
#import "DSECDSAKey.h"

@implementation DSKey

- (UInt160)hash160
{
    return self.publicKeyData.hash160;
}

+ (NSString *)addressWithPublicKeyData:(NSData*)data forChain:(DSChain*)chain
{
    NSParameterAssert(data);
    NSParameterAssert(chain);
    
    NSMutableData *d = [NSMutableData secureDataWithCapacity:160/8 + 1];
    uint8_t version;
    UInt160 hash160 = data.hash160;
    
    if ([chain isMainnet]) {
        version = DASH_PUBKEY_ADDRESS;
    } else {
        version = DASH_PUBKEY_ADDRESS_TEST;
    }
    
    [d appendBytes:&version length:1];
    [d appendBytes:&hash160 length:sizeof(hash160)];
    return [NSString base58checkWithData:d];
}

- (NSString *)addressForChain:(DSChain*)chain
{
    NSParameterAssert(chain);
    
    return [DSKey addressWithPublicKeyData:self.publicKeyData forChain:chain];
}

+ (NSString *)randomAddressForChain:(DSChain*)chain {
    NSParameterAssert(chain);
    
    UInt160 randomNumber = UINT160_ZERO;
    for (int i =0;i<5;i++) {
        randomNumber.u32[i] = arc4random();
    }
    
    return [[NSData dataWithUInt160:randomNumber] addressFromHash160DataForChain:chain];
}

- (NSString *)privateKeyStringForChain:(DSChain*)chain {
    return nil;
}

-(DSKeyType)keyType {
    return 0;
}

-(BOOL)verify:(UInt256)messageDigest signatureData:(NSData *)signature {
    NSAssert(NO, @"This should be overridden");
    return NO;
}

-(NSString*)localizedKeyType {
    switch (self.keyType) {
        case 1:
            return DSLocalizedString(@"ECDSA",nil);
            break;
        case 2:
            return DSLocalizedString(@"BLS",nil);
            break;
        default:
            return DSLocalizedString(@"Unknown Key Type",nil);
            break;
    }
}

+ (DSKey*)keyForPublicKeyData:(NSData*)data forKeyType:(DSKeyType)keyType {
    switch (keyType) {
        case DSKeyType_BLS:
            return [DSBLSKey keyWithPublicKey:data.UInt384];
        case DSKeyType_ECDSA:
            return [DSECDSAKey keyWithPublicKeyData:data];
        default:
            return nil;
    }

}

+ (DSKey*)keyForSecretKeyData:(NSData*)data forKeyType:(DSKeyType)keyType {
    switch (keyType) {
        case DSKeyType_BLS:
            return [DSBLSKey keyWithPrivateKey:data.UInt256];
        case DSKeyType_ECDSA:
            return [DSECDSAKey keyWithSecret:data.UInt256 compressed:YES];
        default:
            return nil;
    }
}

+ (DSKey*)keyForExtendedSecretKeyData:(NSData*)data forKeyType:(DSKeyType)keyType {
    switch (keyType) {
        case DSKeyType_BLS:
            return [DSBLSKey keyWithExtendedPrivateKeyData:data];
        case DSKeyType_ECDSA:
            return [DSECDSAKey keyWithSecret:data.UInt256 compressed:YES];
        default:
            return nil;
    }
}

@end
