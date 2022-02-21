//
//  Created by Vladimir Pirogov
//  Copyright © 2022 Dash Core Group. All rights reserved.
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

#import "DSMasternodeListStore.h"
#import "DSAddressEntity+CoreDataClass.h"
#import "DSBlock.h"
#import "DSChain+Protected.h"
#import "DSChainEntity+CoreDataProperties.h"
#import "DSChainManager.h"
#import "DSCheckpoint.h"
#import "DSDAPIClient.h"
#import "DSLocalMasternodeEntity+CoreDataClass.h"
#import "DSMasternodeListEntity+CoreDataClass.h"
#import "DSMerkleBlock.h"
#import "DSMerkleBlockEntity+CoreDataClass.h"
#import "DSMnDiffProcessingResult.h"
#import "DSOptionsManager.h"
#import "DSQuorumEntryEntity+CoreDataClass.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "DSSimplifiedMasternodeEntryEntity+CoreDataClass.h"
#import "NSData+Dash.h"
#import "NSManagedObject+Sugar.h"

@interface DSMasternodeListStore ()

@property (nonatomic, strong) DSChain *chain;
@property (nonatomic, strong) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, strong) DSMasternodeList *masternodeListAwaitingQuorumValidation;
@property (nonatomic, strong) NSMutableDictionary<NSData *, DSMasternodeList *> *masternodeListsByBlockHash;
@property (nonatomic, strong) NSMutableSet<NSData *> *masternodeListsBlockHashStubs;
@property (nonatomic, strong) NSMutableSet<NSData *> *masternodeListQueriesNeedingQuorumsValidated;
@property (nonatomic, strong) NSMutableDictionary<NSData *, NSNumber *> *cachedBlockHashHeights;
@property (nonatomic, strong) NSData *processingMasternodeListDiffHashes;
@property (nonatomic, strong) dispatch_queue_t masternodeSavingQueue;
@property (nonatomic, assign) UInt256 lastQueriedBlockHash; // last by height, not by time queried
@property (atomic, assign) uint32_t masternodeListCurrentlyBeingSavedCount;

@end

@implementation DSMasternodeListStore

- (instancetype)initWithChain:(DSChain *)chain {
    NSParameterAssert(chain);
    if (!(self = [super init])) return nil;
    _chain = chain;
    _masternodeListsByBlockHash = [NSMutableDictionary dictionary];
    _masternodeListsBlockHashStubs = [NSMutableSet set];
    _masternodeListQueriesNeedingQuorumsValidated = [NSMutableSet set];
    _cachedBlockHashHeights = [NSMutableDictionary dictionary];
    _masternodeListCurrentlyBeingSavedCount = 0;
    _masternodeSavingQueue = dispatch_queue_create([[NSString stringWithFormat:@"org.dashcore.dashsync.masternodesaving.%@", chain.uniqueID] UTF8String], DISPATCH_QUEUE_SERIAL);
    self.lastQueriedBlockHash = UINT256_ZERO;
    self.processingMasternodeListDiffHashes = nil;
    self.managedObjectContext = chain.chainManagedObjectContext;
    return self;
}

- (void)setUp {
    [self deleteEmptyMasternodeLists]; // this is just for sanity purposes
    [self loadMasternodeListsWithBlockHeightLookup:nil];
    [self removeOldSimplifiedMasternodeEntries];
    [self loadLocalMasternodes];
}

- (NSData *_Nullable)messageFromFileForBlockHash:(UInt256)blockHash {
    DSCheckpoint *checkpoint = [self.chain checkpointForBlockHash:blockHash];
    if (!checkpoint || !checkpoint.masternodeListName || [checkpoint.masternodeListName isEqualToString:@""]) {
        DSLog(@"No masternode list checkpoint found at height %u", [self heightForBlockHash:blockHash]);
        return nil;
    }
    NSString *bundlePath = [[NSBundle bundleForClass:self.class] pathForResource:@"DashSync" ofType:@"bundle"];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *filePath = [bundle pathForResource:checkpoint.masternodeListName ofType:@"dat"];
    if (!filePath) {
        return nil;
    }
    NSData *message = [NSData dataWithContentsOfFile:filePath];
    return message;
}

- (void)checkPingTimesForMasternodesInContext:(NSManagedObjectContext *)context withCompletion:(void (^)(NSMutableDictionary<NSData *, NSNumber *> *pingTimes, NSMutableDictionary<NSData *, NSError *> *errors))completion {
    __block NSArray<DSSimplifiedMasternodeEntry *> *entries = self.currentMasternodeList.simplifiedMasternodeEntries;
    [self.chain.chainManager.DAPIClient checkPingTimesForMasternodes:entries
                                                          completion:^(NSMutableDictionary<NSData *, NSNumber *> *_Nonnull pingTimes, NSMutableDictionary<NSData *, NSError *> *_Nonnull errors) {
                                                              [context performBlockAndWait:^{
                                                                  for (DSSimplifiedMasternodeEntry *entry in entries) {
                                                                      [entry savePlatformPingInfoInContext:context];
                                                                  }
                                                                  NSError *savingError = nil;
                                                                  [context save:&savingError];
                                                              }];
                                                              if (completion != nil) {
                                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                                      completion(pingTimes, errors);
                                                                  });
                                                              }
                                                          }];
}

- (NSArray *)recentMasternodeLists {
    return [[self.masternodeListsByBlockHash allValues] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:YES]]];
}

- (NSUInteger)knownMasternodeListsCount {
    NSMutableSet *masternodeListHashes = [NSMutableSet setWithArray:self.masternodeListsByBlockHash.allKeys];
    [masternodeListHashes addObjectsFromArray:[self.masternodeListsBlockHashStubs allObjects]];
    return [masternodeListHashes count];
}

- (uint32_t)earliestMasternodeListBlockHeight {
    uint32_t earliest = UINT32_MAX;
    for (NSData *blockHash in self.masternodeListsBlockHashStubs) {
        earliest = MIN(earliest, [self heightForBlockHash:blockHash.UInt256]);
    }
    for (NSData *blockHash in self.masternodeListsByBlockHash) {
        earliest = MIN(earliest, [self heightForBlockHash:blockHash.UInt256]);
    }
    return earliest;
}

- (uint32_t)lastMasternodeListBlockHeight {
    uint32_t last = 0;
    for (NSData *blockHash in [self.masternodeListsBlockHashStubs copy]) {
        last = MAX(last, [self heightForBlockHash:blockHash.UInt256]);
    }
    for (NSData *blockHash in [self.masternodeListsByBlockHash copy]) {
        last = MAX(last, [self heightForBlockHash:blockHash.UInt256]);
    }
    return last ? last : UINT32_MAX;
}

- (uint32_t)heightForBlockHash:(UInt256)blockhash {
    if (uint256_is_zero(blockhash)) return 0;
    NSNumber *cachedHeightNumber = [self.cachedBlockHashHeights objectForKey:uint256_data(blockhash)];
    if (cachedHeightNumber) return [cachedHeightNumber intValue];
    uint32_t chainHeight = [self.chain heightForBlockHash:blockhash];
    if (chainHeight != UINT32_MAX) [self.cachedBlockHashHeights setObject:@(chainHeight) forKey:uint256_data(blockhash)];
    return chainHeight;
}

- (void)setCurrentMasternodeList:(DSMasternodeList *_Nullable)currentMasternodeList {
    if (self.chain.isEvolutionEnabled) {
        if (!_currentMasternodeList) {
            for (DSSimplifiedMasternodeEntry *masternodeEntry in currentMasternodeList.simplifiedMasternodeEntries) {
                if (masternodeEntry.isValid) {
                    [self.chain.chainManager.DAPIClient addDAPINodeByAddress:masternodeEntry.ipAddressString];
                }
            }
        } else {
            NSDictionary *updates = [currentMasternodeList listOfChangedNodesComparedTo:_currentMasternodeList];
            NSArray *added = updates[MASTERNODE_LIST_ADDED_NODES];
            NSArray *removed = updates[MASTERNODE_LIST_REMOVED_NODES];
            NSArray *addedValidity = updates[MASTERNODE_LIST_ADDED_VALIDITY];
            NSArray *removedValidity = updates[MASTERNODE_LIST_REMOVED_VALIDITY];
            for (DSSimplifiedMasternodeEntry *masternodeEntry in added) {
                if (masternodeEntry.isValid) {
                    [self.chain.chainManager.DAPIClient addDAPINodeByAddress:masternodeEntry.ipAddressString];
                }
            }
            for (DSSimplifiedMasternodeEntry *masternodeEntry in addedValidity) {
                [self.chain.chainManager.DAPIClient addDAPINodeByAddress:masternodeEntry.ipAddressString];
            }
            for (DSSimplifiedMasternodeEntry *masternodeEntry in removed) {
                [self.chain.chainManager.DAPIClient removeDAPINodeByAddress:masternodeEntry.ipAddressString];
            }
            for (DSSimplifiedMasternodeEntry *masternodeEntry in removedValidity) {
                [self.chain.chainManager.DAPIClient removeDAPINodeByAddress:masternodeEntry.ipAddressString];
            }
        }
    }
    bool changed = _currentMasternodeList != currentMasternodeList;
    _currentMasternodeList = currentMasternodeList;
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DSCurrentMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain, DSMasternodeManagerNotificationMasternodeListKey: self.currentMasternodeList ? self.currentMasternodeList : [NSNull null]}];
        });
    }
}

- (UInt256)closestKnownBlockHashForBlockHash:(UInt256)blockHash {
    DSMasternodeList *masternodeList = [self masternodeListBeforeBlockHash:blockHash];
    if (masternodeList)
        return masternodeList.blockHash;
    else
        return self.chain.genesisHash;
}

- (BOOL)currentMasternodeListIsInLast24Hours {
    if (!self.currentMasternodeList) return FALSE;
    DSBlock *block = [self.chain blockForBlockHash:self.currentMasternodeList.blockHash];
    if (!block) return FALSE;
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval delta = currentTimestamp - block.timestamp;
    return fabs(delta) < DAY_TIME_INTERVAL;
}

- (void)deleteAllOnChain {
    [self.managedObjectContext performBlockAndWait:^{
        DSChainEntity *chainEntity = [self.chain chainEntityInContext:self.managedObjectContext];
        [DSSimplifiedMasternodeEntryEntity deleteAllOnChainEntity:chainEntity];
        [DSQuorumEntryEntity deleteAllOnChainEntity:chainEntity];
        [DSMasternodeListEntity deleteAllOnChainEntity:chainEntity];
        [self.managedObjectContext ds_save];
    }];
}

- (void)deleteEmptyMasternodeLists {
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *fetchRequest = [[DSMasternodeListEntity fetchRequest] copy];
        [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"block.chain == %@ && masternodes.@count == 0", [self.chain chainEntityInContext:self.managedObjectContext]]];
        NSArray *masternodeListEntities = [DSMasternodeListEntity fetchObjects:fetchRequest inContext:self.managedObjectContext];
        for (DSMasternodeListEntity *entity in [masternodeListEntities copy]) {
            [self.managedObjectContext deleteObject:entity];
        }
        [self.managedObjectContext ds_save];
    }];
}

- (BOOL)hasBlocksWithHash:(UInt256)blockHash {
    __block BOOL hasBlock = NO;
    [self.managedObjectContext performBlockAndWait:^{
        hasBlock = !![DSMerkleBlockEntity countObjectsInContext:self.managedObjectContext matching:@"blockHash == %@", uint256_data(blockHash)];
    }];
    return hasBlock;
}

- (BOOL)hasMasternodeListAt:(NSData *)blockHashData {
    //    DSLog(@"We already have this masternodeList %@ (%u)", blockHashData.reverse.hexString, [self heightForBlockHash:blockHash]);
    return [self.masternodeListsByBlockHash objectForKey:blockHashData] || [self.masternodeListsBlockHashStubs containsObject:blockHashData];
}

- (BOOL)hasMasternodeListCurrentlyBeingSaved {
    return !!self.masternodeListCurrentlyBeingSavedCount;
}

- (uint32_t)masternodeListsToSync {
    if (self.lastMasternodeListBlockHeight == UINT32_MAX) {
        return 32;
    } else {
        float diff = self.chain.estimatedBlockHeight - self.lastMasternodeListBlockHeight;
        if (diff < 0) return 32;
        return MIN(32, (uint32_t)ceil(diff / 24.0f));
    }
}

- (BOOL)masternodeListsAndQuorumsIsSynced {
    if (self.lastMasternodeListBlockHeight == UINT32_MAX ||
        self.lastMasternodeListBlockHeight < self.chain.estimatedBlockHeight - 16) {
        return NO;
    } else {
        return YES;
    }
}

- (void)loadLocalMasternodes {
    NSFetchRequest *fetchRequest = [[DSLocalMasternodeEntity fetchRequest] copy];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"providerRegistrationTransaction.transactionHash.chain == %@", [self.chain chainEntityInContext:self.managedObjectContext]]];
    NSArray *localMasternodeEntities = [DSLocalMasternodeEntity fetchObjects:fetchRequest inContext:self.managedObjectContext];
    for (DSLocalMasternodeEntity *localMasternodeEntity in localMasternodeEntities) {
        [localMasternodeEntity loadLocalMasternode]; // lazy loaded into the list
    }
}

- (DSMasternodeList *)loadMasternodeListAtBlockHash:(NSData *)blockHash withBlockHeightLookup:(BlockHeightFinder)blockHeightLookup {
    __block DSMasternodeList *masternodeList = nil;
    [self.managedObjectContext performBlockAndWait:^{
        DSMasternodeListEntity *masternodeListEntity = [DSMasternodeListEntity anyObjectInContext:self.managedObjectContext matching:@"block.chain == %@ && block.blockHash == %@", [self.chain chainEntityInContext:self.managedObjectContext], blockHash];
        NSMutableDictionary *simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary *quorumEntryPool = [NSMutableDictionary dictionary];
        masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy] quorumEntryPool:quorumEntryPool withBlockHeightLookup:blockHeightLookup];
        if (masternodeList) {
            [self.masternodeListsByBlockHash setObject:masternodeList forKey:blockHash];
            [self.masternodeListsBlockHashStubs removeObject:blockHash];
            DSLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries", masternodeList.height, uint256_hex(masternodeList.blockHash), (unsigned long)masternodeList.simplifiedMasternodeEntries.count);
        }
    }];
    return masternodeList;
}
- (void)loadMasternodeListsWithBlockHeightLookup:(BlockHeightFinder)blockHeightLookup {
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *fetchRequest = [[DSMasternodeListEntity fetchRequest] copy];
        [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"block.chain == %@", [self.chain chainEntityInContext:self.managedObjectContext]]];
        [fetchRequest setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"block.height" ascending:YES]]];
        NSArray *masternodeListEntities = [DSMasternodeListEntity fetchObjects:fetchRequest inContext:self.managedObjectContext];
        NSMutableDictionary *simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary *quorumEntryPool = [NSMutableDictionary dictionary];
        uint32_t neededMasternodeListHeight = self.chain.lastTerminalBlockHeight - 23; // 2*8+7
        for (uint32_t i = (uint32_t)masternodeListEntities.count - 1; i != UINT32_MAX; i--) {
            DSMasternodeListEntity *masternodeListEntity = [masternodeListEntities objectAtIndex:i];
            if ((i == masternodeListEntities.count - 1) || ((self.masternodeListsByBlockHash.count < 3) && (neededMasternodeListHeight >= masternodeListEntity.block.height))) { // either last one or there are less than 3 (we aim for 3)
                // we only need a few in memory as new quorums will mostly be verified against recent masternode lists
                DSMasternodeList *masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy] quorumEntryPool:quorumEntryPool withBlockHeightLookup:blockHeightLookup];
                [self.masternodeListsByBlockHash setObject:masternodeList forKey:uint256_data(masternodeList.blockHash)];
                [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:uint256_data(masternodeList.blockHash)];
                [simplifiedMasternodeEntryPool addEntriesFromDictionary:masternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash];
                [quorumEntryPool addEntriesFromDictionary:masternodeList.quorums];
                DSLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries", masternodeList.height, uint256_hex(masternodeList.blockHash), (unsigned long)masternodeList.simplifiedMasternodeEntries.count);
                if (i == masternodeListEntities.count - 1) {
                    self.currentMasternodeList = masternodeList;
                }
                neededMasternodeListHeight = masternodeListEntity.block.height - 8;
            } else {
                // just keep a stub around
                [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:masternodeListEntity.block.blockHash];
                [self.masternodeListsBlockHashStubs addObject:masternodeListEntity.block.blockHash];
            }
        }
    }];
}

- (void)reloadMasternodeListsWithBlockHeightLookup:(BlockHeightFinder)blockHeightLookup {
    [self removeAllMasternodeLists];
    self.currentMasternodeList = nil;
    [self loadMasternodeListsWithBlockHeightLookup:blockHeightLookup];
}

- (DSMasternodeList *)masternodeListBeforeBlockHash:(UInt256)blockHash {
    uint32_t minDistance = UINT32_MAX;
    uint32_t blockHeight = [self heightForBlockHash:blockHash];
    DSMasternodeList *closestMasternodeList = nil;
    for (NSData *blockHashData in self.masternodeListsByBlockHash) {
        uint32_t masternodeListBlockHeight = [self heightForBlockHash:blockHashData.UInt256];
        if (blockHeight <= masternodeListBlockHeight) continue;
        uint32_t distance = blockHeight - masternodeListBlockHeight;
        if (distance < minDistance) {
            minDistance = distance;
            closestMasternodeList = self.masternodeListsByBlockHash[blockHashData];
        }
    }
    if (self.chain.isMainnet &&
        closestMasternodeList.height < CHAINLOCK_ACTIVATION_HEIGHT &&
        blockHeight >= CHAINLOCK_ACTIVATION_HEIGHT)
        return nil; // special mainnet case
    return closestMasternodeList;
}

- (DSMasternodeList *)masternodeListForBlockHash:(UInt256)blockHash withBlockHeightLookup:(BlockHeightFinder)blockHeightLookup {
    NSData *blockHashData = uint256_data(blockHash);
    DSMasternodeList *masternodeList = [self.masternodeListsByBlockHash objectForKey:blockHashData];
    if (!masternodeList && [self.masternodeListsBlockHashStubs containsObject:blockHashData]) {
        masternodeList = [self loadMasternodeListAtBlockHash:blockHashData withBlockHeightLookup:blockHeightLookup];
    }
    if (!masternodeList) {
        if (blockHeightLookup) {
            DSLog(@"No masternode list at %@ (%d)", blockHashData.reverse.hexString, blockHeightLookup(blockHash));
        } else {
            DSLog(@"No masternode list at %@", blockHashData.reverse.hexString);
        }
    }
    return masternodeList;
}

- (void)removeAllMasternodeLists {
    [self.masternodeListsByBlockHash removeAllObjects];
    [self.masternodeListsBlockHashStubs removeAllObjects];
    self.currentMasternodeList = nil;
    self.masternodeListAwaitingQuorumValidation = nil;
}

- (void)removeOldMasternodeLists {
    if (!self.currentMasternodeList) return;
    [self.managedObjectContext performBlock:^{
        uint32_t lastBlockHeight = self.currentMasternodeList.height;
        NSMutableArray *masternodeListBlockHashes = [[self.masternodeListsByBlockHash allKeys] mutableCopy];
        [masternodeListBlockHashes addObjectsFromArray:[self.masternodeListsBlockHashStubs allObjects]];
        NSArray<DSMasternodeListEntity *> *masternodeListEntities = [DSMasternodeListEntity objectsInContext:self.managedObjectContext matching:@"block.height < %@ && block.blockHash IN %@ && (block.usedByQuorums.@count == 0)", @(lastBlockHeight - 50), masternodeListBlockHashes];
        BOOL removedItems = !!masternodeListEntities.count;
        for (DSMasternodeListEntity *masternodeListEntity in [masternodeListEntities copy]) {
            DSLog(@"Removing masternodeList at height %u", masternodeListEntity.block.height);
            DSLog(@"quorums are %@", masternodeListEntity.block.usedByQuorums);
            // A quorum is on a block that can only have one masternode list.
            // A block can have one quorum of each type.
            // A quorum references the masternode list by it's block
            // we need to check if this masternode list is being referenced by a quorum using the inverse of quorum.block.masternodeList
            [self.managedObjectContext deleteObject:masternodeListEntity];
            [self.masternodeListsByBlockHash removeObjectForKey:masternodeListEntity.block.blockHash];
        }
        if (removedItems) {
            // Now we should delete old quorums
            // To do this, first get the last 24 active masternode lists
            // Then check for quorums not referenced by them, and delete those
            NSArray<DSMasternodeListEntity *> *recentMasternodeLists = [DSMasternodeListEntity objectsSortedBy:@"block.height" ascending:NO offset:0 limit:10 inContext:self.managedObjectContext];
            uint32_t oldTime = lastBlockHeight - 24;
            uint32_t oldestBlockHeight = recentMasternodeLists.count ? MIN([recentMasternodeLists lastObject].block.height, oldTime) : oldTime;
            NSArray *oldQuorums = [DSQuorumEntryEntity objectsInContext:self.managedObjectContext matching:@"chain == %@ && SUBQUERY(referencedByMasternodeLists, $masternodeList, $masternodeList.block.height > %@).@count == 0", [self.chain chainEntityInContext:self.managedObjectContext], @(oldestBlockHeight)];
            for (DSQuorumEntryEntity *unusedQuorumEntryEntity in [oldQuorums copy]) {
                [self.managedObjectContext deleteObject:unusedQuorumEntryEntity];
            }
            [self.managedObjectContext ds_save];
        }
    }];
}

- (void)removeOldSimplifiedMasternodeEntries {
    // this serves both for cleanup, but also for initial migration
    [self.managedObjectContext performBlockAndWait:^{
        NSArray<DSSimplifiedMasternodeEntryEntity *> *simplifiedMasternodeEntryEntities = [DSSimplifiedMasternodeEntryEntity objectsInContext:self.managedObjectContext matching:@"masternodeLists.@count == 0"];
        BOOL deletedSomething = FALSE;
        NSUInteger deletionCount = 0;
        for (DSSimplifiedMasternodeEntryEntity *simplifiedMasternodeEntryEntity in [simplifiedMasternodeEntryEntities copy]) {
            [self.managedObjectContext deleteObject:simplifiedMasternodeEntryEntity];
            deletedSomething = TRUE;
            deletionCount++;
            if ((deletionCount % 3000) == 0) {
                [self.managedObjectContext ds_save];
            }
        }
        if (deletedSomething) {
            [self.managedObjectContext ds_save];
        }
    }];
}

- (void)saveMasternodeList:(DSMasternodeList *)masternodeList addedMasternodes:(NSDictionary *)addedMasternodes modifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums completion:(void (^)(NSError *error))completion {
    NSData *blockHashData = uint256_data(masternodeList.blockHash);
    if ([self hasMasternodeListAt:blockHashData]) {
        // in rare race conditions this might already exist
        return;
    }
    NSArray *updatedSimplifiedMasternodeEntries = [addedMasternodes.allValues arrayByAddingObjectsFromArray:modifiedMasternodes.allValues];
    [self.chain updateAddressUsageOfSimplifiedMasternodeEntries:updatedSimplifiedMasternodeEntries];
    [self.masternodeListsByBlockHash setObject:masternodeList forKey:blockHashData];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];
        [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];
    });
    // We will want to create unknown blocks if they came from insight
    BOOL createUnknownBlocks = masternodeList.chain.allowInsightBlocksForVerification;
    self.masternodeListCurrentlyBeingSavedCount++;
    // This will create a queue for masternodes to be saved without blocking the networking queue
    dispatch_async(self.masternodeSavingQueue, ^{
        [DSMasternodeListStore saveMasternodeList:masternodeList
                                          toChain:self.chain
                        havingModifiedMasternodes:modifiedMasternodes
                                     addedQuorums:addedQuorums
                              createUnknownBlocks:createUnknownBlocks
                                        inContext:self.managedObjectContext
                                       completion:^(NSError *error) {
                                           self.masternodeListCurrentlyBeingSavedCount--;
                                           completion(error);
                                       }];
    });
}

+ (void)saveMasternodeList:(DSMasternodeList *)masternodeList toChain:(DSChain *)chain havingModifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums createUnknownBlocks:(BOOL)createUnknownBlocks inContext:(NSManagedObjectContext *)context completion:(void (^)(NSError *error))completion {
    DSLog(@"Queued saving MNL at height %u", masternodeList.height);
    [context performBlockAndWait:^{
        // masternodes
        DSChainEntity *chainEntity = [chain chainEntityInContext:context];
        DSMerkleBlockEntity *merkleBlockEntity = [DSMerkleBlockEntity anyObjectInContext:context matching:@"blockHash == %@", uint256_data(masternodeList.blockHash)];
        if (!merkleBlockEntity && ([chain checkpointForBlockHash:masternodeList.blockHash])) {
            DSCheckpoint *checkpoint = [chain checkpointForBlockHash:masternodeList.blockHash];
            merkleBlockEntity = [[DSMerkleBlockEntity managedObjectInBlockedContext:context] setAttributesFromBlock:[checkpoint blockForChain:chain] forChainEntity:chainEntity];
        }
        NSAssert(!merkleBlockEntity || !merkleBlockEntity.masternodeList, @"Merkle block should not have a masternode list already");
        NSError *error = nil;
        if (!merkleBlockEntity) {
            if (createUnknownBlocks) {
                merkleBlockEntity = [DSMerkleBlockEntity managedObjectInBlockedContext:context];
                merkleBlockEntity.blockHash = uint256_data(masternodeList.blockHash);
                merkleBlockEntity.height = masternodeList.height;
                merkleBlockEntity.chain = chainEntity;
            } else {
                DSLog(@"Merkle block should exist for block hash %@", uint256_data(masternodeList.blockHash));
                error = [NSError errorWithDomain:@"DashSync" code:600 userInfo:@{NSLocalizedDescriptionKey: @"Merkle block should exist"}];
            }
        } else if (merkleBlockEntity.masternodeList) {
            error = [NSError errorWithDomain:@"DashSync" code:600 userInfo:@{NSLocalizedDescriptionKey: @"Merkle block should not have a masternode list already"}];
        }
        if (!error) {
            DSMasternodeListEntity *masternodeListEntity = [DSMasternodeListEntity managedObjectInBlockedContext:context];
            masternodeListEntity.block = merkleBlockEntity;
            masternodeListEntity.masternodeListMerkleRoot = uint256_data(masternodeList.masternodeMerkleRoot);
            masternodeListEntity.quorumListMerkleRoot = uint256_data(masternodeList.quorumMerkleRoot);
            uint32_t i = 0;
            NSArray<DSSimplifiedMasternodeEntryEntity *> *knownSimplifiedMasternodeEntryEntities = [DSSimplifiedMasternodeEntryEntity objectsInContext:context matching:@"chain == %@", chainEntity];
            NSMutableDictionary *indexedKnownSimplifiedMasternodeEntryEntities = [NSMutableDictionary dictionary];
            for (DSSimplifiedMasternodeEntryEntity *simplifiedMasternodeEntryEntity in knownSimplifiedMasternodeEntryEntities) {
                [indexedKnownSimplifiedMasternodeEntryEntities setObject:simplifiedMasternodeEntryEntity forKey:simplifiedMasternodeEntryEntity.providerRegistrationTransactionHash];
            }
            NSMutableSet<NSString *> *votingAddressStrings = [NSMutableSet set];
            NSMutableSet<NSString *> *operatorAddressStrings = [NSMutableSet set];
            NSMutableSet<NSData *> *providerRegistrationTransactionHashes = [NSMutableSet set];
            for (DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry in masternodeList.simplifiedMasternodeEntries) {
                [votingAddressStrings addObject:simplifiedMasternodeEntry.votingAddress];
                [operatorAddressStrings addObject:simplifiedMasternodeEntry.operatorAddress];
                [providerRegistrationTransactionHashes addObject:uint256_data(simplifiedMasternodeEntry.providerRegistrationTransactionHash)];
            }
            // this is the initial list sync so lets speed things up a little bit with some optimizations
            NSDictionary<NSString *, DSAddressEntity *> *votingAddresses = [DSAddressEntity findAddressesAndIndexIn:votingAddressStrings onChain:(DSChain *)chain inContext:context];
            NSDictionary<NSString *, DSAddressEntity *> *operatorAddresses = [DSAddressEntity findAddressesAndIndexIn:votingAddressStrings onChain:(DSChain *)chain inContext:context];
            NSDictionary<NSData *, DSLocalMasternodeEntity *> *localMasternodes = [DSLocalMasternodeEntity findLocalMasternodesAndIndexForProviderRegistrationHashes:providerRegistrationTransactionHashes inContext:context];
            NSAssert(masternodeList.simplifiedMasternodeEntries, @"A masternode must have entries to be saved");
            for (DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry in masternodeList.simplifiedMasternodeEntries) {
                DSSimplifiedMasternodeEntryEntity *simplifiedMasternodeEntryEntity = [indexedKnownSimplifiedMasternodeEntryEntities objectForKey:uint256_data(simplifiedMasternodeEntry.providerRegistrationTransactionHash)];
                if (!simplifiedMasternodeEntryEntity) {
                    simplifiedMasternodeEntryEntity = [DSSimplifiedMasternodeEntryEntity managedObjectInBlockedContext:context];
                    [simplifiedMasternodeEntryEntity setAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry atBlockHeight:masternodeList.height knownOperatorAddresses:operatorAddresses knownVotingAddresses:votingAddresses localMasternodes:localMasternodes onChainEntity:chainEntity];
                } else if (simplifiedMasternodeEntry.updateHeight >= masternodeList.height) {
                    // it was updated in this masternode list
                    [simplifiedMasternodeEntryEntity updateAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry atBlockHeight:masternodeList.height knownOperatorAddresses:operatorAddresses knownVotingAddresses:votingAddresses localMasternodes:localMasternodes];
                }
                [masternodeListEntity addMasternodesObject:simplifiedMasternodeEntryEntity];
                i++;
            }
            for (NSData *simplifiedMasternodeEntryHash in modifiedMasternodes) {
                DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry = modifiedMasternodes[simplifiedMasternodeEntryHash];
                DSSimplifiedMasternodeEntryEntity *simplifiedMasternodeEntryEntity = [indexedKnownSimplifiedMasternodeEntryEntities objectForKey:uint256_data(simplifiedMasternodeEntry.providerRegistrationTransactionHash)];
                NSAssert(simplifiedMasternodeEntryEntity, @"this must be present");
                [simplifiedMasternodeEntryEntity updateAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry atBlockHeight:masternodeList.height knownOperatorAddresses:operatorAddresses knownVotingAddresses:votingAddresses localMasternodes:localMasternodes];
            }
            for (NSNumber *llmqType in masternodeList.quorums) {
                NSDictionary *quorumsForMasternodeType = masternodeList.quorums[llmqType];
                for (NSData *quorumHash in quorumsForMasternodeType) {
                    DSQuorumEntry *potentialQuorumEntry = quorumsForMasternodeType[quorumHash];
                    DSQuorumEntryEntity *quorumEntry = [DSQuorumEntryEntity quorumEntryEntityFromPotentialQuorumEntry:potentialQuorumEntry inContext:context];
                    if (quorumEntry) {
                        [masternodeListEntity addQuorumsObject:quorumEntry];
                    }
                }
            }
            chainEntity.baseBlockHash = [NSData dataWithUInt256:masternodeList.blockHash];
            error = [context ds_save];
            DSLog(@"Finished saving MNL at height %u", masternodeList.height);
        }
        if (error) {
            chainEntity.baseBlockHash = uint256_data(chain.genesisHash);
            [DSLocalMasternodeEntity deleteAllOnChainEntity:chainEntity];
            [DSSimplifiedMasternodeEntryEntity deleteAllOnChainEntity:chainEntity];
            [DSQuorumEntryEntity deleteAllOnChainEntity:chainEntity];
            [context ds_save];
        }
        if (completion) {
            completion(error);
        }
    }];
}

- (DSSimplifiedMasternodeEntry *_Nullable)masternodeEntryWithProRegTxHash:(NSData *)proRegTxHash {
    NSParameterAssert(proRegTxHash);
    return [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash objectForKey:proRegTxHash];
}


- (DSSimplifiedMasternodeEntry *_Nullable)masternodeEntryForLocation:(UInt128)IPAddress port:(uint16_t)port {
    for (DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry in [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash allValues]) {
        if (uint128_eq(simplifiedMasternodeEntry.address, IPAddress) && simplifiedMasternodeEntry.port == port) {
            return simplifiedMasternodeEntry;
        }
    }
    return nil;
}

- (DSQuorumEntry *_Nullable)quorumEntryForPlatformHavingQuorumHash:(UInt256)quorumHash forBlockHeight:(uint32_t)blockHeight {
    DSBlock *block = [self.chain blockAtHeight:blockHeight];
    if (block == nil) {
        if (blockHeight > self.chain.lastTerminalBlockHeight) {
            block = self.chain.lastTerminalBlock;
        } else {
            return nil;
        }
    }
    return [self quorumEntryForPlatformHavingQuorumHash:quorumHash forBlock:block];
}

- (DSQuorumEntry *)quorumEntryForPlatformHavingQuorumHash:(UInt256)quorumHash forBlock:(DSBlock *)block {
    DSMasternodeList *masternodeList = [self masternodeListForBlockHash:block.blockHash withBlockHeightLookup:nil];
    if (!masternodeList) {
        masternodeList = [self masternodeListBeforeBlockHash:block.blockHash];
    }
    if (!masternodeList) {
        DSLog(@"No masternode list found yet");
        return nil;
    }
    if (block.height - masternodeList.height > 32) {
        DSLog(@"Masternode list is too old");
        return nil;
    }
    DSQuorumEntry *quorumEntry = [masternodeList quorumEntryForPlatformWithQuorumHash:quorumHash];
    if (quorumEntry == nil) {
        quorumEntry = [self quorumEntryForPlatformHavingQuorumHash:quorumHash forBlockHeight:block.height - 1];
    }
    return quorumEntry;
}

- (DSQuorumEntry *)quorumEntryForChainLockRequestID:(UInt256)requestID forMerkleBlock:(DSMerkleBlock *)merkleBlock {
    DSMasternodeList *masternodeList = [self masternodeListBeforeBlockHash:merkleBlock.blockHash];
    if (!masternodeList) {
        DSLog(@"No masternode list found yet");
        return nil;
    }
    if (merkleBlock.height - masternodeList.height > 24) {
        DSLog(@"Masternode list is too old");
        return nil;
    }
    return [masternodeList quorumEntryForChainLockRequestID:requestID];
}

- (DSQuorumEntry *)quorumEntryForInstantSendRequestID:(UInt256)requestID withBlockHeightOffset:(uint32_t)blockHeightOffset {
    DSMerkleBlock *merkleBlock = [self.chain blockFromChainTip:blockHeightOffset];
    DSMasternodeList *masternodeList = [self masternodeListBeforeBlockHash:merkleBlock.blockHash];
    if (!masternodeList) {
        DSLog(@"No masternode list found yet");
        return nil;
    }
    if (merkleBlock.height - masternodeList.height > 32) {
        DSLog(@"Masternode list for IS is too old (age: %d masternodeList height %d merkle block height %d)", merkleBlock.height - masternodeList.height, masternodeList.height, merkleBlock.height);
        return nil;
    }
    return [masternodeList quorumEntryForInstantSendRequestID:requestID];
}

- (BOOL)addBlockToValidationQueue:(DSMerkleBlock *)merkleBlock {
    UInt256 merkleBlockHash = merkleBlock.blockHash;
    NSData *merkleBlockHashData = uint256_data(merkleBlockHash);
    if ([self hasMasternodeListAt:merkleBlockHashData]) {
        DSLog(@"Already have that masternode list (or in stub) %u", merkleBlock.height);
        return NO;
    }
    self.lastQueriedBlockHash = merkleBlockHash;
    [self.masternodeListQueriesNeedingQuorumsValidated addObject:merkleBlockHashData];
    return YES;
}

@end
