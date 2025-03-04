//
//  Created by Vladimir Pirogov
//  Copyright © 2021 Dash Core Group. All rights reserved.
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

#import "DSChain.h"
#import "DSMasternodeDiffMessageContext.h"
#import "DSMasternodeList.h"
#import "DSMasternodeManager.h"
#import "DSQuorumEntry.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "dash_shared_core.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSMasternodeManager (Mndiff)

const MasternodeList *masternodeListLookupCallback(uint8_t (*block_hash)[32], const void *context);
void masternodeListDestroyCallback(const MasternodeList *masternode_list);
uint32_t blockHeightListLookupCallback(uint8_t (*block_hash)[32], const void *context);
void addInsightLookup(uint8_t (*block_hash)[32], const void *context);
bool shouldProcessQuorumType(uint8_t quorum_type, const void *context);
bool validateQuorumCallback(QuorumValidationData *data, const void *context);


+ (MasternodeList *)wrapMasternodeList:(DSMasternodeList *)list;
+ (void)freeMasternodeList:(MasternodeList *)list;

+ (MasternodeEntry *)wrapMasternodeEntry:(DSSimplifiedMasternodeEntry *)entry;
+ (void)freeMasternodeEntry:(MasternodeEntry *)entry;

+ (QuorumEntry *)wrapQuorumEntry:(DSQuorumEntry *)entry;
+ (void)freeQuorumEntry:(QuorumEntry *)entry;

+ (void)processMasternodeDiffMessage:(NSData *)message withContext:(DSMasternodeDiffMessageContext *)context completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists))completion;

@end


NS_ASSUME_NONNULL_END
