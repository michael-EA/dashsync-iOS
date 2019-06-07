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

@property (nonatomic, assign) BOOL user1HasProfile;
@property (nonatomic, assign) BOOL user2HasProfile;

@property (nonatomic, assign) BOOL user1StateTransitionsFetched;
@property (nonatomic, assign) BOOL user2StateTransitionsFetched;

@property (nonatomic, assign) BOOL user1ProfileFetched;
@property (nonatomic, assign) BOOL user2ProfileFetched;

@property (nonatomic, assign) BOOL contactRequestSent;

@property (nonatomic, assign) BOOL user1IncomingContactRequestsFetched;
@property (nonatomic, assign) BOOL user2IncomingContactRequestsFetched;

@property (nonatomic, assign) BOOL user1OutgoingContactRequestsFetched;
@property (nonatomic, assign) BOOL user2OutgoingContactRequestsFetched;

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
    
    [self waitForNumberOfBlocks:2];
}

- (void)test_05_registerProfiles {
    BOOL canRunTest = STRG.blockchainUser1 && STRG.blockchainUser2;
    XCTAssert(canRunTest);
    if (!canRunTest) {
        return;
    }
    
    NSLog(@">>> registering profile 1 %@", STRG.blockchainUser1.username);
    XCTestExpectation *registerProfile1Expectation = [[XCTestExpectation alloc] initWithDescription:@"User 1 profile should be registered"];
    [self registerProfile:STRG.blockchainUser1 completion:^(BOOL success) {
        XCTAssert(success);
        STRG.user1HasProfile = success;
        [registerProfile1Expectation fulfill];
    }];
    [self waitForExpectations:@[registerProfile1Expectation] timeout:60];
    
    NSLog(@">>> registering profile 2 %@", STRG.blockchainUser2.username);
    XCTestExpectation *registerProfile2Expectation = [[XCTestExpectation alloc] initWithDescription:@"User 2 profile should be registered"];
    [self registerProfile:STRG.blockchainUser2 completion:^(BOOL success) {
        XCTAssert(success);
        STRG.user2HasProfile = success;
        [registerProfile2Expectation fulfill];
    }];
    [self waitForExpectations:@[registerProfile2Expectation] timeout:60];
    
    [self waitForNumberOfBlocks:2];
}

- (void)test_06_fetchStateTransitions {
    BOOL canRunTest = STRG.user1HasProfile && STRG.user2HasProfile;
    XCTAssert(canRunTest);
    if (!canRunTest) {
        return;
    }

    NSLog(@">>> fetching transitions 1 %@", STRG.blockchainUser1.username);
    XCTestExpectation *expectation1 = [[XCTestExpectation alloc] initWithDescription:@"User 1 transitions should be fetched"];
    [self fetchTransitions:STRG.blockchainUser1 completion:^(BOOL success) {
        XCTAssert(success);
        STRG.user1StateTransitionsFetched = success;
        [expectation1 fulfill];
    }];
    [self waitForExpectations:@[expectation1] timeout:60];
    
    NSLog(@">>> fetching transitions 2 %@", STRG.blockchainUser2.username);
    XCTestExpectation *expectation2 = [[XCTestExpectation alloc] initWithDescription:@"User 2 transitions should be fetched"];
    [self fetchTransitions:STRG.blockchainUser2 completion:^(BOOL success) {
        XCTAssert(success);
        STRG.user2StateTransitionsFetched = success;
        [expectation2 fulfill];
    }];
    [self waitForExpectations:@[expectation2] timeout:60];
}

- (void)test_07_fetchProfiles {
    BOOL canRunTest = STRG.user1StateTransitionsFetched && STRG.user2StateTransitionsFetched;
    XCTAssert(canRunTest);
    if (!canRunTest) {
        return;
    }
    
    NSLog(@">>> fetching profile 1 %@", STRG.blockchainUser1.username);
    XCTestExpectation *expectation1 = [[XCTestExpectation alloc] initWithDescription:@"User 1 profile should be fetched"];
    [STRG.blockchainUser1 fetchProfile:^(BOOL success) {
        XCTAssert(success);
        STRG.user1ProfileFetched = success;
        [expectation1 fulfill];
    }];
    [self waitForExpectations:@[expectation1] timeout:60];
    
    NSLog(@">>> fetching profile 2 %@", STRG.blockchainUser2.username);
    XCTestExpectation *expectation2 = [[XCTestExpectation alloc] initWithDescription:@"User 2 profile should be fetched"];
    [STRG.blockchainUser2 fetchProfile:^(BOOL success) {
        XCTAssert(success);
        STRG.user2ProfileFetched = success;
        [expectation2 fulfill];
    }];
    [self waitForExpectations:@[expectation2] timeout:60];
}

- (void)test_08_sendContactRequest {
    BOOL canRunTest = STRG.user1ProfileFetched && STRG.user2ProfileFetched;
    XCTAssert(canRunTest);
    if (!canRunTest) {
        return;
    }
    
    NSString *username = STRG.blockchainUser2.username;
    DSBlockchainUser *blockchainUser = STRG.blockchainUser1;
    DSAccount *account = [blockchainUser.wallet accountWithNumber:0];
    NSParameterAssert(account);
    
    XCTestExpectation *expectation = [[XCTestExpectation alloc] initWithDescription:@"User 1 should send contact request"];
    
    NSLog(@">>> Sending contact request from user 1 to 2");
    
    DSPotentialContact *potentialContact = [[DSPotentialContact alloc] initWithUsername:username];
    [blockchainUser sendNewFriendRequestToPotentialContact:potentialContact completion:^(BOOL success) {
        XCTAssert(success);
        STRG.contactRequestSent = success;
        [expectation fulfill];
    }];
    [self waitForExpectations:@[expectation] timeout:60];
    
    [self waitForNumberOfBlocks:1];
}

- (void)test_09_fetchIncomingContactRequests {
    BOOL canRunTest = STRG.contactRequestSent;
    XCTAssert(canRunTest);
    if (!canRunTest) {
        return;
    }
    
    NSLog(@">>> fetching incoming contact requests 1 %@", STRG.blockchainUser1.username);
    XCTestExpectation *expectation1 = [[XCTestExpectation alloc] initWithDescription:@"User 1 incoming contact requests should be fetched"];
    [STRG.blockchainUser1 fetchIncomingContactRequests:^(BOOL success) {
        XCTAssert(success);
        STRG.user1IncomingContactRequestsFetched = success;
        [expectation1 fulfill];
    }];
    [self waitForExpectations:@[expectation1] timeout:60];
    
    NSLog(@">>> fetching incoming contact requests 2 %@", STRG.blockchainUser2.username);
    XCTestExpectation *expectation2 = [[XCTestExpectation alloc] initWithDescription:@"User 2 incoming contact requests should be fetched"];
    [STRG.blockchainUser2 fetchIncomingContactRequests:^(BOOL success) {
        XCTAssert(success);
        STRG.user2IncomingContactRequestsFetched = success;
        [expectation2 fulfill];
    }];
    [self waitForExpectations:@[expectation2] timeout:60];
}

- (void)test_09_fetchOutgoingContactRequests {
    BOOL canRunTest = STRG.user1IncomingContactRequestsFetched && STRG.user2IncomingContactRequestsFetched;
    XCTAssert(canRunTest);
    if (!canRunTest) {
        return;
    }
    
    NSLog(@">>> fetching outgoing contact requests 1 %@", STRG.blockchainUser1.username);
    XCTestExpectation *expectation1 = [[XCTestExpectation alloc] initWithDescription:@"User 1 outgoing contact requests should be fetched"];
    [STRG.blockchainUser1 fetchOutgoingContactRequests:^(BOOL success) {
        XCTAssert(success);
        STRG.user1OutgoingContactRequestsFetched = success;
        [expectation1 fulfill];
    }];
    [self waitForExpectations:@[expectation1] timeout:60];
    
    NSLog(@">>> fetching outgoing contact requests 2 %@", STRG.blockchainUser2.username);
    XCTestExpectation *expectation2 = [[XCTestExpectation alloc] initWithDescription:@"User 2 outgoing contact requests should be fetched"];
    [STRG.blockchainUser2 fetchOutgoingContactRequests:^(BOOL success) {
        XCTAssert(success);
        STRG.user2OutgoingContactRequestsFetched = success;
        [expectation2 fulfill];
    }];
    [self waitForExpectations:@[expectation2] timeout:60];
}

#pragma mark - Private

- (void)registerBlockchainUser:(NSString *)username completion:(void(^)(DSBlockchainUser * _Nullable))completion {
    DSWallet *wallet = STRG.wallet;
    DSAccount *fundingAccount = nil;
    for (DSAccount * account in wallet.accounts) {
        if (account.balance > 0) {
            fundingAccount = account;
            break;
        }
    }
    XCTAssertNotNil(fundingAccount);
    
    if (!fundingAccount) {
        completion(nil);
        return;
    }
    
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
                            completion(nil);
                        }
                    }];
                } else {
                    XCTAssert(NO, @"Unable to create BlockchainUserRegistrationTransaction.");
                    completion(nil);
                }
            }];
        } else {
            XCTAssert(NO, @"Unable to register blockchain user.");
            completion(nil);
        }
    }];
}

- (void)waitForNumberOfBlocks:(uint32_t)blocksToWait {
    uint32_t currentBlockHeight = STRG.chainManager.chain.lastBlockHeight;
    
    XCTNSNotificationExpectation *expectation = [[XCTNSNotificationExpectation alloc] initWithName:DSChainBlocksDidChangeNotification];
    expectation.handler = ^BOOL(NSNotification * _Nonnull notification) {
        return STRG.chainManager.chain.lastBlockHeight >= currentBlockHeight + blocksToWait;
    };
    
    // wait 15 minutes * blocks_count
    [self waitForExpectations:@[expectation] timeout:60 * 15 * blocksToWait];
}

- (void)registerProfile:(DSBlockchainUser *)blockchainUser completion:(void(^)(BOOL success))completion {
    NSString *aboutMe = [NSString stringWithFormat:@"Hey I'm test demo user %@", blockchainUser.username];
    NSString *avatarURLString = [NSString stringWithFormat:@"https://api.adorable.io/avatars/120/%@.png",
                                 blockchainUser.username];
    [blockchainUser createOrUpdateProfileWithAboutMeString:aboutMe
                                           avatarURLString:avatarURLString
                                                completion:completion];
}

- (void)fetchTransitions:(DSBlockchainUser *)blockchainUser completion:(void(^)(BOOL success))completion {
    [STRG.chainManager.DAPIClient getAllStateTransitionsForUser:blockchainUser completion:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"Fetch transitions failed: %@", error);
        }
        
        completion(error == nil);
    }];
}

@end
