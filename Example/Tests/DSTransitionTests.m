//  
//  Created by Sam Westrich
//  Copyright © 2020 Dash Core Group. All rights reserved.
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
#import "DSECDSAKey.h"
#import "DSChain.h"
#import "NSString+Bitcoin.h"
#import "DSTransaction.h"
#import "NSMutableData+Dash.h"
#import "DSBlockchainIdentityRegistrationTransition.h"
#import "DSBlockchainIdentityTopupTransition.h"
#import "DSBlockchainIdentityUpdateTransition.h"
#import "DSBlockchainIdentityCloseTransition.h"
#import "DSBlockchainIdentity+Protected.h"
#import "DSTransactionFactory.h"
#import "DSChainManager.h"
#import "NSData+Dash.h"
#import "DSTransactionManager.h"
#import "DSMasternodeManager.h"
#import "DSSporkManager.h"
#import "DSChainsManager.h"
#import "DSMerkleBlock.h"
#import "DSWallet.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "DSDerivationPath.h"
#import "DSFundsDerivationPath.h"
#import "DSAuthenticationKeysDerivationPath.h"
#import "DSMasternodeHoldingsDerivationPath.h"
#import "DSProviderRegistrationTransaction.h"
#import "DSProviderUpdateServiceTransaction.h"
#import "DSProviderUpdateRegistrarTransaction.h"
#import "DSTransition+Protected.h"
#import "DSCreditFundingTransaction.h"
#import "DSDocumentTransition.h"

@interface DSTransitionTests : XCTestCase

@property (nonatomic,strong) DSBlockchainIdentity * blockchainIdentity;
@property (nonatomic,strong) DSChain * chain;
@property (nonatomic,strong) DSWallet * testWallet;
@property (nonatomic,strong) DSAccount * testAccount;

@end

@implementation DSTransitionTests

- (void)setUp {
    self.chain = [DSChain setUpDevnetWithIdentifier:@"0" withCheckpoints:nil withDefaultPort:20001 withDefaultDapiJRPCPort:3000 withDefaultDapiGRPCPort:3010 dpnsContractID:UINT256_ZERO dashpayContractID:UINT256_ZERO isTransient:YES];
    self.testWallet = [DSWallet standardWalletWithRandomSeedPhraseInLanguage:DSBIP39Language_English forChain:self.chain storeSeedPhrase:NO isTransient:YES];
    NSData * transactionData = @"0300000002b74030bbda6edd804d4bfb2bdbbb7c207a122f3af2f6283de17074a42c6a5417020000006b483045022100815b175ab1a8fde7d651d78541ba73d2e9b297e6190f5244e1957004aa89d3c902207e1b164499569c1f282fe5533154495186484f7db22dc3dc1ccbdc9b47d997250121027f69794d6c4c942392b1416566aef9eaade43fbf07b63323c721b4518127baadffffffffb74030bbda6edd804d4bfb2bdbbb7c207a122f3af2f6283de17074a42c6a5417010000006b483045022100a7c94fe1bb6ffb66d2bb90fd8786f5bd7a0177b0f3af20342523e64291f51b3e02201f0308f1034c0f6024e368ca18949be42a896dda434520fa95b5651dc5ad3072012102009e3f2eb633ee12c0143f009bf773155a6c1d0f14271d30809b1dc06766aff0ffffffff031027000000000000166a1414ec6c36e6c39a9181f3a261a08a5171425ac5e210270000000000001976a91414ec6c36e6c39a9181f3a261a08a5171425ac5e288acc443953b000000001976a9140d1775b9ed85abeb19fd4a7d8cc88b08a29fe6de88ac00000000".hexToData;
    DSCreditFundingTransaction * fundingTransaction = [[DSCreditFundingTransaction alloc] initWithMessage:transactionData onChain:self.chain];
    self.testAccount = [self.testWallet accountWithNumber:0];
    
    [self.testAccount registerTransaction:fundingTransaction];
    
    self.blockchainIdentity = [[DSBlockchainIdentity alloc] initWithFundingTransaction:fundingTransaction withUsernameDictionary:nil inWallet:self.testWallet inContext:nil];
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void)testNameRegistration {
    DSECDSAKey * privateKey = [DSECDSAKey keyWithSecret:@"fdbca0cd2be4375f04fcaee5a61c5d170a2a46b1c0c7531f58c430734a668f32".hexToData.UInt256 compressed:YES];
    
    [self.blockchainIdentity addUsername:@"dash" save:NO];
    
    DSDocumentTransition * transition = self.blockchainIdentity.unregisteredUsernamesPreorderTransition;
    
    NSLog(@"%@",transition.keyValueDictionary);
}

- (void)testProfileCreation {
    DSECDSAKey * privateKey = [DSECDSAKey keyWithSecret:@"fdbca0cd2be4375f04fcaee5a61c5d170a2a46b1c0c7531f58c430734a668f32".hexToData.UInt256 compressed:YES];
    
    [self.blockchainIdentity addUsername:@"dash" save:NO];
    
    DSDocumentTransition * transition = self.blockchainIdentity.unregisteredUsernamesPreorderTransition;
    
    NSLog(@"%@",transition.keyValueDictionary);
}

-(void)testIdentityRegistrationData {
    NSData * identityRegistrationData =  @"a7647479706503697369676e6174757265785851523979496d674d4942304446517061486b696247314248476f716b5130695064637a5a48343452394f6d625a486e6b77664c424e467638696a6e62466e4238313239476a466779624a316b4c5133636a674e6b6432562b6a7075626c69634b65797381a4626964006464617461782c416e68306b5335646a706e4c4570314e446366494b464e447759484579436376695855735a62614d36797955647479706501696973456e61626c6564f56c6964656e7469747954797065016e6c6f636b65644f7574506f696e747830654c66354a4d365a6d433137795646676d4534346f72462b694c715974566739517941525a575843646a3042414141416f70726f746f636f6c56657273696f6e00747369676e61747572655075626c69634b6579496400".hexToData;
    DSBlockchainIdentityRegistrationTransition * blockchainIdentityRegistrationTransition = [[DSBlockchainIdentityRegistrationTransition alloc] initWithData:identityRegistrationData onChain:self.chain];
    DSKey * key = [blockchainIdentityRegistrationTransition.publicKeys allValues][0];
    XCTAssertEqualObjects(key.publicKeyData.hexString, @"027874912e5d8e99cb129d4d0dc7c8285343c181c4c8272f89752c65b68ceb2c94");
    XCTAssertEqual(key.keyType, DSKeyType_ECDSA);
    XCTAssertEqualObjects(uint256_hex(blockchainIdentityRegistrationTransition.blockchainIdentityUniqueId), @"fd0851e8705c4989dc4f36e676c0d8c8cae9e5ff278bcbccb4d827b6f078290c");
    XCTAssertEqual(blockchainIdentityRegistrationTransition.type, DSTransitionType_IdentityRegistration);
}

@end
