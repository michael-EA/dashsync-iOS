//
//  NSString+Dash.m
//  DashSync
//
//  Created by Aaron Voisine for BreadWallet on 5/13/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//  Copyright (c) 2018 Dash Core Group <contact@dash.org>
//  Updated by Quantum Explorer on 05/11/18.
//  Copyright (c) 2018 Quantum Explorer <quantum@dash.org>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "DSChain.h"
#import "DSDerivationPath.h"
#import "DSECDSAKey.h"
#import "DSPriceManager.h"
#import "NSData+DSHash.h"
#import "NSMutableData+Dash.h"
#import "NSString+Dash.h"
#if TARGET_OS_IOS
#import "UIImage+DSUtils.h"
#else
#import "NSImage+DSUtils.h"
#endif

static NSString *DashCurrencySymbolAssetName = nil;

@implementation NSString (Dash)

+ (void)setDashCurrencySymbolAssetName:(NSString *)imageName {
    NSParameterAssert(imageName);
#if TARGET_OS_IOS
    NSAssert([UIImage imageNamed:imageName], @"Dash currency symbol asset doesn't exist");
#endif
    DashCurrencySymbolAssetName = imageName;
}

// NOTE: It's important here to be permissive with scriptSig (spends) and strict with scriptPubKey (receives). If we
// miss a receive transaction, only that transaction's funds are missed, however if we accept a receive transaction that
// we are unable to correctly sign later, then the entire wallet balance after that point would become stuck with the
// current coin selection code
+ (NSString *)addressWithScriptPubKey:(NSData *)script onChain:(DSChain *)chain {
    if (script == (id)[NSNull null]) return nil;

    NSArray *elem = [script scriptElements];
    NSUInteger l = elem.count;
    NSMutableData *d = [NSMutableData data];
    uint8_t v;

    if ([chain isMainnet]) {
        v = DASH_PUBKEY_ADDRESS;
    } else {
        v = DASH_PUBKEY_ADDRESS_TEST;
    }

    if (l == 5 && [elem[0] intValue] == OP_DUP && [elem[1] intValue] == OP_HASH160 && [elem[2] intValue] == 20 &&
        [elem[3] intValue] == OP_EQUALVERIFY && [elem[4] intValue] == OP_CHECKSIG) {
        // pay-to-pubkey-hash scriptPubKey
        [d appendBytes:&v length:1];
        [d appendData:elem[2]];
    } else if (l == 3 && [elem[0] intValue] == OP_HASH160 && [elem[1] intValue] == 20 && [elem[2] intValue] == OP_EQUAL) {
        // pay-to-script-hash scriptPubKey
        if ([chain isMainnet]) {
            v = DASH_SCRIPT_ADDRESS;
        } else {
            v = DASH_SCRIPT_ADDRESS_TEST;
        }
        [d appendBytes:&v length:1];
        [d appendData:elem[1]];
    } else if (l == 2 && ([elem[0] intValue] == 65 || [elem[0] intValue] == 33) && [elem[1] intValue] == OP_CHECKSIG) {
        // pay-to-pubkey scriptPubKey
        [d appendBytes:&v length:1];
        [d appendBytes:[elem[0] hash160].u8 length:sizeof(UInt160)];
    } else
        return nil; // unknown script type

    return [self base58checkWithData:d];
}

+ (NSString *)addressWithHash160:(UInt160)hash160 onChain:(DSChain *)chain {
    uint8_t v;
    NSMutableData *d = [NSMutableData data];
    if ([chain isMainnet]) {
        v = DASH_PUBKEY_ADDRESS;
    } else {
        v = DASH_PUBKEY_ADDRESS_TEST;
    }
    [d appendBytes:&v length:1];
    [d appendUInt160:hash160];
    return [self base58checkWithData:d];
}

+ (NSString *)addressWithScriptSig:(NSData *)script onChain:(DSChain *)chain {
    if (script == (id)[NSNull null]) return nil;

    NSArray *elem = [script scriptElements];
    NSUInteger l = elem.count;
    NSMutableData *d = [NSMutableData data];
    uint8_t v;

    if ([chain isMainnet]) {
        v = DASH_PUBKEY_ADDRESS;
    } else {
        v = DASH_PUBKEY_ADDRESS_TEST;
    }


    if (l >= 2 && [elem[l - 2] intValue] <= OP_PUSHDATA4 && [elem[l - 2] intValue] > 0 &&
        ([elem[l - 1] intValue] == 65 || [elem[l - 1] intValue] == 33)) { // pay-to-pubkey-hash scriptSig
        [d appendBytes:&v length:1];
        [d appendBytes:[elem[l - 1] hash160].u8 length:sizeof(UInt160)];
    } else if (l >= 2 && [elem[l - 2] intValue] <= OP_PUSHDATA4 && [elem[l - 2] intValue] > 0 &&
               [elem[l - 1] intValue] <= OP_PUSHDATA4 && [elem[l - 1] intValue] > 0) { // pay-to-script-hash scriptSig
        if ([chain isMainnet]) {
            v = DASH_SCRIPT_ADDRESS;
        } else {
            v = DASH_SCRIPT_ADDRESS_TEST;
        }
        [d appendBytes:&v length:1];
        [d appendBytes:[elem[l - 1] hash160].u8 length:sizeof(UInt160)];
    } else if (l >= 1 && [elem[l - 1] intValue] <= OP_PUSHDATA4 && [elem[l - 1] intValue] > 0) { // pay-to-pubkey scriptSig
        [d appendBytes:&v length:1];
        //        DSKey * key = [DSKey keyRecoveredFromCompactSig:elem[l - 1] andMessageDigest:transactionHash];
        //        [d appendBytes:[key.publicKey hash160].u8 length:sizeof(UInt160)];
        //TODO: implement Peter Wullie's pubKey recovery from signature
        return nil;
    } else {
        DSLog(@"Unknown script type");
        return nil; // unknown script type
    }

    return [self base58checkWithData:d];
}

- (BOOL)isValidDashAddressOnChain:(DSChain *)chain {
    if (self.length > 35) return NO;

    NSData *d = self.base58checkToData;

    if (d.length != 21) return NO;

    uint8_t version = *(const uint8_t *)d.bytes;
    if ([chain isMainnet]) {
        return (version == DASH_PUBKEY_ADDRESS || version == DASH_SCRIPT_ADDRESS);
    } else {
        return (version == DASH_PUBKEY_ADDRESS_TEST || version == DASH_SCRIPT_ADDRESS_TEST);
    }
}

- (BOOL)isValidDashDevnetAddress {
    if (self.length > 35) return NO;

    NSData *d = self.base58checkToData;

    if (d.length != 21) return NO;

    uint8_t version = *(const uint8_t *)d.bytes;

    return (version == DASH_PUBKEY_ADDRESS_TEST || version == DASH_SCRIPT_ADDRESS_TEST);
}

- (BOOL)isValidDashPrivateKeyOnChain:(DSChain *)chain {
    if (![self isValidBase58]) return FALSE;
    NSData *d = self.base58checkToData;

    if (d.length == 33 || d.length == 34) { // wallet import format: https://en.bitcoin.it/wiki/Wallet_import_format
        if ([chain isMainnet]) {
            return (*(const uint8_t *)d.bytes == DASH_PRIVKEY);
        } else {
            return (*(const uint8_t *)d.bytes == DASH_PRIVKEY_TEST);
        }
    } else
        return (self.hexToData.length == 32); // hex encoded key
}

- (BOOL)isValidDashDevnetPrivateKey {
    if (![self isValidBase58]) return FALSE;
    NSData *d = self.base58checkToData;

    if (d.length == 33 || d.length == 34) { // wallet import format: https://en.bitcoin.it/wiki/Wallet_import_format
        return (*(const uint8_t *)d.bytes == DASH_PRIVKEY_TEST);
    } else
        return (self.hexToData.length == 32); // hex encoded key
}

- (BOOL)isValidDashExtendedPublicKeyOnChain:(DSChain *)chain {
    if (![self isValidBase58]) return FALSE;
    NSData *allData = self.base58ToData;
    if (allData.length != 82) return FALSE;
    NSData *data = [allData subdataWithRange:NSMakeRange(0, allData.length - 4)];
    NSData *checkData = [allData subdataWithRange:NSMakeRange(allData.length - 4, 4)];
    if ((*(uint32_t *)data.SHA256_2.u32) != *(uint32_t *)checkData.bytes) return FALSE;
    uint8_t *bytes = (uint8_t *)[data bytes];
    if (memcmp(bytes, [chain isMainnet] ? BIP32_XPRV_MAINNET : BIP32_XPRV_TESTNET, 4) != 0 && memcmp(bytes, [chain isMainnet] ? BIP32_XPUB_MAINNET : BIP32_XPUB_TESTNET, 4) != 0) {
        return FALSE;
    }
    return TRUE;
}

// BIP38 encrypted keys: https://github.com/bitcoin/bips/blob/master/bip-0038.mediawiki
- (BOOL)isValidDashBIP38Key {
    NSData *d = self.base58checkToData;

    if (d.length != 39) return NO; // invalid length

    uint16_t prefix = CFSwapInt16BigToHost(*(const uint16_t *)d.bytes);
    uint8_t flag = ((const uint8_t *)d.bytes)[2];

    if (prefix == BIP38_NOEC_PREFIX) { // non EC multiplied key
        return ((flag & BIP38_NOEC_FLAG) == BIP38_NOEC_FLAG && (flag & BIP38_LOTSEQUENCE_FLAG) == 0 &&
                (flag & BIP38_INVALID_FLAG) == 0);
    } else if (prefix == BIP38_EC_PREFIX) { // EC multiplied key
        return ((flag & BIP38_NOEC_FLAG) == 0 && (flag & BIP38_INVALID_FLAG) == 0);
    } else
        return NO; // invalid prefix
}

#if TARGET_OS_IOS

- (NSAttributedString *)attributedStringForDashSymbol {
    return [self attributedStringForDashSymbolWithTintColor:[UIColor blackColor]];
}

- (NSAttributedString *)attributedStringForDashSymbolWithTintColor:(UIColor *)color {
    return [self attributedStringForDashSymbolWithTintColor:color dashSymbolSize:CGSizeMake(12, 12)];
}

+ (NSAttributedString *)dashSymbolAttributedStringWithTintColor:(UIColor *)color forDashSymbolSize:(CGSize)dashSymbolSize {
    NSAssert(DashCurrencySymbolAssetName, @"Provide Dash currency symbol asset by calling setDashCurrencySymbolAssetName:");

    NSTextAttachment *dashSymbol = [[NSTextAttachment alloc] init];

    dashSymbol.bounds = CGRectMake(0, 0, dashSymbolSize.width, dashSymbolSize.height);
    dashSymbol.image = [[UIImage imageNamed:DashCurrencySymbolAssetName] ds_imageWithTintColor:color];
    return [NSAttributedString attributedStringWithAttachment:dashSymbol];
}


- (NSAttributedString *)attributedStringForDashSymbolWithTintColor:(UIColor *)color dashSymbolSize:(CGSize)dashSymbolSize {
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc]
        initWithString:[self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];

    NSRange range = [attributedString.string rangeOfString:DASH];
    if (range.location == NSNotFound) {
        [attributedString insertAttributedString:[[NSAttributedString alloc] initWithString:@" "] atIndex:0];
        [attributedString insertAttributedString:[NSString dashSymbolAttributedStringWithTintColor:color forDashSymbolSize:dashSymbolSize] atIndex:0];

        [attributedString addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, attributedString.length)];
    } else {
        [attributedString replaceCharactersInRange:range
                              withAttributedString:[NSString dashSymbolAttributedStringWithTintColor:color forDashSymbolSize:dashSymbolSize]];
        [attributedString addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, attributedString.length)];
    }
    return attributedString;
}

#else

- (NSAttributedString *)attributedStringForDashSymbol {
    return [self attributedStringForDashSymbolWithTintColor:[NSColor blackColor]];
}

- (NSAttributedString *)attributedStringForDashSymbolWithTintColor:(NSColor *)color {
    return [self attributedStringForDashSymbolWithTintColor:color dashSymbolSize:CGSizeMake(12, 12)];
}

+ (NSAttributedString *)dashSymbolAttributedStringWithTintColor:(NSColor *)color forDashSymbolSize:(CGSize)dashSymbolSize {
    NSAssert(DashCurrencySymbolAssetName, @"Provide Dash currency symbol asset by calling setDashCurrencySymbolAssetName:");

    NSTextAttachment *dashSymbol = [[NSTextAttachment alloc] init];

    dashSymbol.bounds = CGRectMake(0, 0, dashSymbolSize.width, dashSymbolSize.height);
    dashSymbol.image = [[NSImage imageNamed:DashCurrencySymbolAssetName] ds_imageWithTintColor:color];
    return [NSAttributedString attributedStringWithAttachment:dashSymbol];
}


- (NSAttributedString *)attributedStringForDashSymbolWithTintColor:(NSColor *)color dashSymbolSize:(CGSize)dashSymbolSize {
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc]
        initWithString:[self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];

    NSRange range = [attributedString.string rangeOfString:DASH];
    if (range.location == NSNotFound) {
        [attributedString insertAttributedString:[[NSAttributedString alloc] initWithString:@" "] atIndex:0];
        [attributedString insertAttributedString:[NSString dashSymbolAttributedStringWithTintColor:color forDashSymbolSize:dashSymbolSize] atIndex:0];

        [attributedString addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, attributedString.length)];
    } else {
        [attributedString replaceCharactersInRange:range
                              withAttributedString:[NSString dashSymbolAttributedStringWithTintColor:color forDashSymbolSize:dashSymbolSize]];
        [attributedString addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, attributedString.length)];
    }
    return attributedString;
}

#endif


- (NSInteger)indexOfCharacter:(unichar)character {
    for (int i = 0; i < self.length; i++) {
        if ([self characterAtIndex:i] == character) return i;
    }
    return NSNotFound;
}

- (UInt256)magicDigest {
    NSMutableData *stringMessageData = [NSMutableData data];
    [stringMessageData appendString:DASH_MESSAGE_MAGIC];
    [stringMessageData appendString:self];
    return stringMessageData.SHA256_2;
}

// MARK: time

+ (NSString *)waitTimeFromNow:(NSTimeInterval)wait {
    NSUInteger seconds = wait;
    NSUInteger hours = seconds / 3600;
    seconds %= 3600;
    NSUInteger minutes = seconds / 60;
    seconds %= 60;

    if (hours > 0) {
        NSString *hoursString = [NSString localizedStringWithFormat:
                                              DSLocalizedString(@"%ld hour(s)", @"#bc-ignore!"), hours];
        return hoursString;
    }

    if (minutes > 0) {
        NSString *minutesString = [NSString localizedStringWithFormat:
                                                DSLocalizedString(@"%ld minute(s)", @"#bc-ignore!"), minutes];
        return minutesString;
    }

    NSString *secondsString = [NSString localizedStringWithFormat:
                                            DSLocalizedString(@"%ld second(s)", @"#bc-ignore!"), seconds];
    return secondsString;
}

@end
