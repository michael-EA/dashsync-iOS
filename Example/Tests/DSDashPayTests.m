//  
//  Created by Andrew Podkovyrin
//  Copyright © 2019 Dash Core Group. All rights reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <XCTest/XCTest.h>

#import <DashSync/DashSync.h>

// Each test runs on a separate XCTestCase instance; state is shared via this singleton
@interface DSDashPayTestsStorage: NSObject

@property (nonatomic, strong) DSChain *chain;
@property (nonatomic, strong) DSChainManager *chainManager;
@property (nonatomic, strong) DSWallet *wallet;

@property (nonatomic, strong) DSBlockchainUser *blockchainUser1;
@property (nonatomic, strong) DSBlockchainUser *blockchainUser2;

@end

@implementation DSDashPayTestsStorage

+ (instancetype)sharedInstance {
    static DSDashPayTestsStorage *_sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });
    return _sharedInstance;
}

@end

#define STRG [DSDashPayTestsStorage sharedInstance]

#pragma mark - Tests

@interface DSDashPayTests : XCTestCase

@end

@implementation DSDashPayTests

// Run tests in alphabetic order
+ (NSArray<NSInvocation *> *)testInvocations {
    return [[super testInvocations] sortedArrayUsingComparator:^NSComparisonResult(NSInvocation *invocation1,
                                                                                   NSInvocation *invocation2) {
        return [NSStringFromSelector(invocation1.selector) compare:NSStringFromSelector(invocation2.selector)];
    }];
}

- (void)test_01_setupDevnet {
    NSArray *devnetChains = [[DSChainsManager sharedInstance] devnetChains];
    
    NSString *const portoIdentifier = @"devnet-porto";
    DSChain *portoChain = nil;
    for (DSChain *chain in devnetChains) {
        if ([chain.devnetIdentifier isEqualToString:portoIdentifier]) {
            portoChain = chain;
            break;
        }
    }
    
    if (!portoChain) {
        uint32_t protocolVersion = 70213;
        uint32_t minProtocolVersion = 70212;
        NSString * sporkAddress = nil;
        NSString * sporkPrivateKey = nil;
        uint32_t dashdPort = 20001;
        uint32_t dapiPort = DEVNET_DAPI_STANDARD_PORT;
        portoChain = [[DSChainsManager sharedInstance] registerDevnetChainWithIdentifier:portoIdentifier
                                                                     forServiceLocations:[NSMutableOrderedSet orderedSetWithObject:@"18.237.69.61:20001"]
                                                                            standardPort:dashdPort
                                                                                dapiPort:dapiPort
                                                                         protocolVersion:protocolVersion
                                                                      minProtocolVersion:minProtocolVersion
                                                                            sporkAddress:sporkAddress
                                                                         sporkPrivateKey:sporkPrivateKey];
    }
    
    XCTAssertNotNil(portoChain);
    STRG.chain = portoChain;
    STRG.chainManager = [[DSChainsManager sharedInstance] chainManagerForChain:portoChain];
}

- (void)test_02_addWallet {
    DSChain *chain = STRG.chain;
    NSString *uniqueID = @"53e0b49";
    
    NSUInteger index = [chain.wallets indexOfObjectPassingTest:^BOOL(DSWallet * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        return [obj.uniqueID isEqualToString:uniqueID];
    }];
    
    if (index == NSNotFound) {
        // after updating wallet seed phrase make sure to update uniqueID constant
        NSString *seedPhrase = @"sail upper barrel furnance word mask hurt napkin filter address middle note";
        NSTimeInterval creationDate = 1558428119;
        DSWallet *wallet = [DSWallet standardWalletWithSeedPhrase:seedPhrase
                                                  setCreationDate:creationDate
                                                         forChain:chain
                                                  storeSeedPhrase:YES
                                                      isTransient:NO];
        [chain registerWallet:wallet];

        XCTAssertEqualObjects(wallet.uniqueID, uniqueID);
    }
    
    
    index = [chain.wallets indexOfObjectPassingTest:^BOOL(DSWallet * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        return [obj.uniqueID isEqualToString:uniqueID];
    }];
    
    STRG.wallet = chain.wallets[index];
    
    XCTAssert(index != NSNotFound);
}

- (void)test_03_sync {
    __block BOOL isProgressDone = NO;
    __block BOOL isSyncFinished = NO;
    
    XCTNSNotificationExpectation *expectation = [[XCTNSNotificationExpectation alloc] initWithName:DSChainBlocksDidChangeNotification];
    expectation.handler = ^BOOL(NSNotification * _Nonnull notification) {
        NSLog(@">>> sync progress %f", STRG.chainManager.syncProgress);
        isProgressDone = STRG.chainManager.syncProgress >= 1.0;
        return isProgressDone || isSyncFinished;
    };
    
    XCTNSNotificationExpectation *finishExpectation = [[XCTNSNotificationExpectation alloc] initWithName:DSTransactionManagerSyncFinishedNotification];
    finishExpectation.handler = ^BOOL(NSNotification * _Nonnull notification) {
        isSyncFinished = YES;
        return isSyncFinished || isProgressDone;
    };
    
    [[DashSync sharedSyncController] startSyncForChain:STRG.chain];
    
    [self waitForExpectations:@[expectation, finishExpectation] timeout:60 * 3]; // 3 min
}

- (void)test_04_registerBlockchainUsers {
    NSString *username = [[NSUUID UUID].UUIDString componentsSeparatedByString:@"-"].lastObject;
    
    XCTestExpectation *registerBU1Expectation = [[XCTestExpectation alloc] initWithDescription:@"Blockchain user 1 should be registered"];
    [self registerBlockchainUser:username completion:^(DSBlockchainUser *blockchainUser) {
        XCTAssertNotNil(blockchainUser);
        STRG.blockchainUser1 = blockchainUser;
        [registerBU1Expectation fulfill];
    }];
    
    [self waitForExpectations:@[registerBU1Expectation] timeout:1];
    
    XCTestExpectation *registerBU2Expectation = [[XCTestExpectation alloc] initWithDescription:@"Blockchain user 2 should be registered"];
    username = [[NSUUID UUID].UUIDString componentsSeparatedByString:@"-"].lastObject;
    [self registerBlockchainUser:username completion:^(DSBlockchainUser *blockchainUser) {
        XCTAssertNotNil(blockchainUser);
        STRG.blockchainUser2 = blockchainUser;
        [registerBU2Expectation fulfill];
    }];
    
    [self waitForExpectations:@[registerBU2Expectation] timeout:1];
    
    uint32_t currentBlockHeight = STRG.chainManager.chain.lastBlockHeight;
    uint32_t blocksToWait = 2;
    
    XCTNSNotificationExpectation *expectation = [[XCTNSNotificationExpectation alloc] initWithName:DSChainBlocksDidChangeNotification];
    expectation.handler = ^BOOL(NSNotification * _Nonnull notification) {
        return STRG.chainManager.chain.lastBlockHeight >= currentBlockHeight + blocksToWait;
    };

    [self waitForExpectations:@[expectation] timeout:60 * 30]; // 30 min
}

#pragma mark - Private

- (void)registerBlockchainUser:(NSString *)username completion:(void(^)(DSBlockchainUser *))completion {
    DSWallet *wallet = STRG.wallet;
    DSAccount *fundingAccount = nil;
    for (DSAccount * account in wallet.accounts) {
        if (account.balance > 0) {
            fundingAccount = account;
            break;
        }
    }
    XCTAssertNotNil(fundingAccount);
    
    uint64_t topupAmount = 10000000;

    DSBlockchainUser * blockchainUser = [STRG.wallet createBlockchainUserForUsername:username];
    [blockchainUser generateBlockchainUserExtendedPublicKey:^(BOOL exists) {
        if (exists) {
            [blockchainUser registrationTransactionForTopupAmount:topupAmount fundedByAccount:fundingAccount completion:^(DSBlockchainUserRegistrationTransaction *blockchainUserRegistrationTransaction) {
                if (blockchainUserRegistrationTransaction) {
                    [fundingAccount signTransaction:blockchainUserRegistrationTransaction withPrompt:@"Would you like to create this user?" completion:^(BOOL signedTransaction, BOOL cancelled) {
                        if (signedTransaction) {
                            [STRG.chainManager.transactionManager publishTransaction:blockchainUserRegistrationTransaction completion:^(NSError * _Nullable error) {
                                if (error) {
                                    XCTAssert(NO, @"%@", error.localizedDescription);
                                    completion(nil);
                                } else {
                                    [blockchainUser registerInWalletForBlockchainUserRegistrationTransaction:blockchainUserRegistrationTransaction];
                                    completion(blockchainUser);
                                }
                            }];
                        } else {
                            XCTAssert(NO, @"Transaction was not signed.");
                        }
                    }];
                } else {
                    XCTAssert(NO, @"Unable to create BlockchainUserRegistrationTransaction.");
                }
            }];
        } else {
            XCTAssert(NO, @"Unable to register blockchain user.");
        }
    }];
}

@end
