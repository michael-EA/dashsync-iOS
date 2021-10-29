//
//  DSMasternodeManager.m
//  DashSync
//
//  Created by Sam Westrich on 6/7/18.
//  Copyright (c) 2018 Dash Core Group <contact@dash.org>
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

#import "DSMasternodeManager.h"
#import "DSAddressEntity+CoreDataProperties.h"
#import "DSChain+Protected.h"
#import "DSChainEntity+CoreDataProperties.h"
#import "DSChainManager+Protected.h"
#import "DSCheckpoint.h"
#import "DSDAPIClient.h"
#import "DSDerivationPath.h"
#import "DSInsightManager.h"
#import "DSLocalMasternode+Protected.h"
#import "DSLocalMasternodeEntity+CoreDataClass.h"
#import "DSMasternodeList.h"
#import "DSMasternodeListEntity+CoreDataClass.h"
#import "DSMerkleBlock.h"
#import "DSMerkleBlockEntity+CoreDataClass.h"
#import "DSMerkleTree.h"
#import "DSMutableOrderedDataKeyDictionary.h"
#import "DSOptionsManager.h"
#import "DSPeer.h"
#import "DSPeerManager+Protected.h"
#import "DSPeerManager.h"
#import "DSProviderRegistrationTransaction.h"
#import "DSProviderRegistrationTransactionEntity+CoreDataClass.h"
#import "DSQuorumEntry.h"
#import "DSQuorumEntryEntity+CoreDataClass.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "DSSimplifiedMasternodeEntryEntity+CoreDataClass.h"
#import "DSTransactionFactory.h"
#import "DSTransactionManager+Protected.h"
#import "NSArray+Dash.h"
#import "NSData+DSHash.h"
#import "NSDictionary+Dash.h"
#import "NSManagedObject+Sugar.h"
#import "NSMutableData+Dash.h"
#import "NSString+Bitcoin.h"
#import "NSString+Dash.h"
#import "NSValue+Sugar.h"

#define FAULTY_DML_MASTERNODE_PEERS @"FAULTY_DML_MASTERNODE_PEERS"
#define CHAIN_FAULTY_DML_MASTERNODE_PEERS [NSString stringWithFormat:@"%@_%@", peer.chain.uniqueID, FAULTY_DML_MASTERNODE_PEERS]
#define MAX_FAULTY_DML_PEERS 2

#define LOG_MASTERNODE_DIFF (0 && DEBUG)
#define KEEP_OLD_QUORUMS 0
#define SAVE_MASTERNODE_DIFF_TO_FILE (0 && DEBUG)
#define SAVE_MASTERNODE_ERROR_TO_FILE (0 && DEBUG)
#define SAVE_MASTERNODE_NO_ERROR_TO_FILE (0 && DEBUG)
#define DSFullLog(FORMAT, ...) printf("%s\n", [[NSString stringWithFormat:FORMAT, ##__VA_ARGS__] UTF8String])


@interface DSMasternodeManager ()

@property (nonatomic, strong) DSChain *chain;
@property (nonatomic, strong) DSMasternodeList *currentMasternodeList;
@property (nonatomic, strong) DSMasternodeList *masternodeListAwaitingQuorumValidation;
@property (nonatomic, strong) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, strong) NSMutableSet *masternodeListQueriesNeedingQuorumsValidated;
@property (nonatomic, assign) UInt256 lastQueriedBlockHash; //last by height, not by time queried
@property (nonatomic, strong) NSData *processingMasternodeListDiffHashes;
@property (nonatomic, strong) NSMutableDictionary<NSData *, DSMasternodeList *> *masternodeListsByBlockHash;
@property (nonatomic, strong) NSMutableSet<NSData *> *masternodeListsBlockHashStubs;
@property (nonatomic, strong) NSMutableDictionary<NSData *, NSNumber *> *cachedBlockHashHeights;
@property (nonatomic, strong) NSMutableDictionary<NSData *, DSLocalMasternode *> *localMasternodesDictionaryByRegistrationTransactionHash;
@property (nonatomic, strong) NSMutableOrderedSet<NSData *> *masternodeListRetrievalQueue;
@property (nonatomic, assign) NSUInteger masternodeListRetrievalQueueMaxAmount;
@property (nonatomic, strong) NSMutableSet<NSData *> *masternodeListsInRetrieval;
@property (nonatomic, assign) NSTimeInterval timeIntervalForMasternodeRetrievalSafetyDelay;
@property (nonatomic, assign) uint16_t timedOutAttempt;
@property (nonatomic, assign) uint16_t timeOutObserverTry;
@property (atomic, assign) uint32_t masternodeListCurrentlyBeingSavedCount;
@property (nonatomic, strong) NSDictionary<NSData *, NSString *> *fileDistributedMasternodeLists; //string is the path
@property (nonatomic, strong) dispatch_queue_t masternodeSavingQueue;

@end

@implementation DSMasternodeManager

- (instancetype)initWithChain:(DSChain *)chain {
    NSParameterAssert(chain);

    if (!(self = [super init])) return nil;
    _masternodeSavingQueue = dispatch_queue_create([[NSString stringWithFormat:@"org.dashcore.dashsync.masternodesaving.%@", chain.uniqueID] UTF8String], DISPATCH_QUEUE_SERIAL);
    _chain = chain;
    _masternodeListRetrievalQueue = [NSMutableOrderedSet orderedSet];
    _masternodeListsInRetrieval = [NSMutableSet set];
    _masternodeListsByBlockHash = [NSMutableDictionary dictionary];
    _masternodeListsBlockHashStubs = [NSMutableSet set];
    _masternodeListQueriesNeedingQuorumsValidated = [NSMutableSet set];
    _cachedBlockHashHeights = [NSMutableDictionary dictionary];
    _localMasternodesDictionaryByRegistrationTransactionHash = [NSMutableDictionary dictionary];
    _testingMasternodeListRetrieval = NO;
    self.managedObjectContext = chain.chainManagedObjectContext;
    self.lastQueriedBlockHash = UINT256_ZERO;
    self.processingMasternodeListDiffHashes = nil;
    _timedOutAttempt = 0;
    _timeOutObserverTry = 0;
    _masternodeListCurrentlyBeingSavedCount = 0;
    return self;
}

// MARK: - Helpers

- (DSPeerManager *)peerManager {
    return self.chain.chainManager.peerManager;
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

- (UInt256)closestKnownBlockHashForBlockHash:(UInt256)blockHash {
    DSMasternodeList *masternodeList = [self masternodeListBeforeBlockHash:blockHash];
    if (masternodeList)
        return masternodeList.blockHash;
    else
        return self.chain.genesisHash;
}

- (NSUInteger)activeQuorumsCount {
    return self.currentMasternodeList.quorumsCount;
}

- (DSSimplifiedMasternodeEntry *)simplifiedMasternodeEntryForLocation:(UInt128)IPAddress port:(uint16_t)port {
    for (DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry in [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash allValues]) {
        if (uint128_eq(simplifiedMasternodeEntry.socketAddress.ipAddress, IPAddress) &&
            simplifiedMasternodeEntry.socketAddress.port == port) {
            return simplifiedMasternodeEntry;
        }
    }
    return nil;
}

- (DSSimplifiedMasternodeEntry *)masternodeHavingProviderRegistrationTransactionHash:(NSData *)providerRegistrationTransactionHash {
    NSParameterAssert(providerRegistrationTransactionHash);

    return [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash objectForKey:providerRegistrationTransactionHash];
}

- (BOOL)hasMasternodeAtLocation:(UInt128)IPAddress port:(uint32_t)port {
    DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry = [self simplifiedMasternodeEntryForLocation:IPAddress port:port];
    return (!!simplifiedMasternodeEntry);
}

- (NSUInteger)masternodeListRetrievalQueueCount {
    return self.masternodeListRetrievalQueue.count;
}

- (uint32_t)estimatedMasternodeListsToSync {
    BOOL syncMasternodeLists = ([[DSOptionsManager sharedInstance] syncType] & DSSyncType_MasternodeList);
    if (!syncMasternodeLists) {
        return 0;
    }
    double amountLeft = self.masternodeListRetrievalQueue.count;
    double maxAmount = self.masternodeListRetrievalQueueMaxAmount;
    double masternodeListsCount = self.masternodeListsByBlockHash.count;
    if (!maxAmount || masternodeListsCount <= 1) { //1 because there might be a default
        if (self.lastMasternodeListBlockHeight == UINT32_MAX) {
            return 32;
        } else {
            float diff = self.chain.estimatedBlockHeight - self.lastMasternodeListBlockHeight;
            if (diff < 0) return 32;
            return MIN(32, (uint32_t)ceil(diff / 24.0f));
        }
    }
    return amountLeft;
}

- (double)masternodeListAndQuorumsSyncProgress {
    double amountLeft = self.masternodeListRetrievalQueue.count;
    double maxAmount = self.masternodeListRetrievalQueueMaxAmount;
    if (!amountLeft) {
        if (self.lastMasternodeListBlockHeight == UINT32_MAX || self.lastMasternodeListBlockHeight < self.chain.estimatedBlockHeight - 16) {
            return 0;
        } else {
            return 1;
        }
    }
    double progress = MAX(MIN((maxAmount - amountLeft) / maxAmount, 1), 0);
    return progress;
}

- (BOOL)currentMasternodeListIsInLast24Hours {
    if (!self.currentMasternodeList) return FALSE;
    DSBlock *block = [self.chain blockForBlockHash:self.currentMasternodeList.blockHash];
    if (!block) return FALSE;
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval delta = currentTimestamp - block.timestamp;
    return fabs(delta) < DAY_TIME_INTERVAL;
}


// MARK: - Set Up and Tear Down

- (void)setUp {
    [self deleteEmptyMasternodeLists]; //this is just for sanity purposes
    [self loadMasternodeLists];
    [self removeOldSimplifiedMasternodeEntries];
    [self loadLocalMasternodes];
    [self loadFileDistributedMasternodeLists];
}

- (void)loadLocalMasternodes {
    NSFetchRequest *fetchRequest = [[DSLocalMasternodeEntity fetchRequest] copy];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"providerRegistrationTransaction.transactionHash.chain == %@", [self.chain chainEntityInContext:self.managedObjectContext]]];
    NSArray *localMasternodeEntities = [DSLocalMasternodeEntity fetchObjects:fetchRequest inContext:self.managedObjectContext];
    for (DSLocalMasternodeEntity *localMasternodeEntity in localMasternodeEntities) {
        [localMasternodeEntity loadLocalMasternode]; // lazy loaded into the list
    }
}

- (void)reloadMasternodeLists {
    [self reloadMasternodeListsWithBlockHeightLookup:nil];
}

- (void)reloadMasternodeListsWithBlockHeightLookup:(uint32_t (^)(UInt256 blockHash))blockHeightLookup {
    [self.masternodeListsByBlockHash removeAllObjects];
    [self.masternodeListsBlockHashStubs removeAllObjects];
    self.currentMasternodeList = nil;
    [self loadMasternodeListsWithBlockHeightLookup:blockHeightLookup];
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

- (void)loadMasternodeLists {
    [self loadMasternodeListsWithBlockHeightLookup:nil];
}

- (void)loadMasternodeListsWithBlockHeightLookup:(uint32_t (^)(UInt256 blockHash))blockHeightLookup {
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *fetchRequest = [[DSMasternodeListEntity fetchRequest] copy];
        [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"block.chain == %@", [self.chain chainEntityInContext:self.managedObjectContext]]];
        [fetchRequest setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"block.height" ascending:YES]]];
        NSArray *masternodeListEntities = [DSMasternodeListEntity fetchObjects:fetchRequest inContext:self.managedObjectContext];
        NSMutableDictionary *simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary *quorumEntryPool = [NSMutableDictionary dictionary];
        uint32_t neededMasternodeListHeight = self.chain.lastTerminalBlockHeight - 23; //2*8+7
        for (uint32_t i = (uint32_t)masternodeListEntities.count - 1; i != UINT32_MAX; i--) {
            DSMasternodeListEntity *masternodeListEntity = [masternodeListEntities objectAtIndex:i];
            if ((i == masternodeListEntities.count - 1) || ((self.masternodeListsByBlockHash.count < 3) && (neededMasternodeListHeight >= masternodeListEntity.block.height))) { //either last one or there are less than 3 (we aim for 3)
                //we only need a few in memory as new quorums will mostly be verified against recent masternode lists
                DSMasternodeList *masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy]
                                                                                                         quorumEntryPool:quorumEntryPool
                                                                                                   withBlockHeightLookup:blockHeightLookup];
                NSData *blockHashData = uint256_data(masternodeList.blockHash);
                [self.masternodeListsByBlockHash setObject:masternodeList forKey:blockHashData];
                [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:blockHashData];
                [simplifiedMasternodeEntryPool addEntriesFromDictionary:masternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash];
                [quorumEntryPool addEntriesFromDictionary:masternodeList.quorums];
                DSLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries", masternodeList.height, uint256_hex(masternodeList.blockHash), (unsigned long)masternodeList.simplifiedMasternodeEntries.count);
                if (i == masternodeListEntities.count - 1) {
                    self.currentMasternodeList = masternodeList;
                }
                neededMasternodeListHeight = masternodeListEntity.block.height - 8;
            } else {
                //just keep a stub around
                [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:masternodeListEntity.block.blockHash];
                [self.masternodeListsBlockHashStubs addObject:masternodeListEntity.block.blockHash];
            }
        }
    }];
}

- (void)updateDAPIClientNodes:(NSDictionary<NSData *, DSSimplifiedMasternodeEntry *> *)previousEntries
             atPreviousHeight:(uint32_t)previousHeight
           withCurrentEntries:(NSDictionary<NSData *, DSSimplifiedMasternodeEntry *> *)currentEntries
              atCurrentHeight:(uint32_t)currentHeight {
    // We need to keep those addresses where is at least one port is in the white list
    // But for now it's prohibited to use multiple instances on the same ip

    NSArray<DSSimplifiedMasternodeEntry *> *prevEntries = [previousEntries allValues];
    NSArray<DSSimplifiedMasternodeEntry *> *currEntries = [currentEntries allValues];
    NSMutableArray<NSString *> *prevIPs = [NSMutableArray arrayWithCapacity:[prevEntries count]];
    NSMutableArray<NSString *> *currIPs = [NSMutableArray arrayWithCapacity:[currEntries count]];
    for (DSSimplifiedMasternodeEntry *entry in prevEntries) {
        [prevIPs addObject:entry.ipAddressString];
    }
    for (DSSimplifiedMasternodeEntry *entry in currEntries) {
        if ([entry isValid])
            [currIPs addObject:entry.ipAddressString];
    }

    NSMutableSet *prevSet = [NSMutableSet setWithArray:prevIPs];
    NSMutableSet *currSet = [NSMutableSet setWithArray:currIPs];
    NSMutableSet *setToRemove = [prevSet mutableCopy];
    [setToRemove minusSet:currSet];
    NSMutableSet *setToAdd = [currSet mutableCopy];
    [setToAdd minusSet:prevSet];

    for (NSString *ipToRemove in setToRemove) {
        [self.chain.chainManager.DAPIClient removeDAPINodeByAddress:ipToRemove];
    }

    for (NSString *ipToAdd in setToAdd) {
        [self.chain.chainManager.DAPIClient addDAPINodeByAddress:ipToAdd];
    }
}

- (void)setWhiteList:(NSArray <NSValue*> *)whiteList {
    _whiteList = whiteList;
    NSMutableSet *stringSet = [NSMutableSet set];
    for (NSValue *address in whiteList) {
        [stringSet addObject:[NSString stringWithSocketAddress:[address socketAddressValue]]];
    }
    [self.chain.chainManager.DAPIClient setWhiteList:stringSet];
}

- (void)setCurrentMasternodeList:(DSMasternodeList *)currentMasternodeList {
    if (self.chain.isEvolutionEnabled) {
        if (!_currentMasternodeList) {
            for (DSSimplifiedMasternodeEntry *masternodeEntry in currentMasternodeList.simplifiedMasternodeEntries) {
                if (masternodeEntry.isValid) {
                    [self.chain.chainManager.DAPIClient addDAPINodeByAddress:masternodeEntry.ipAddressString];
                }
            }
        } else {
            [self updateDAPIClientNodes:_currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash atPreviousHeight:_currentMasternodeList.height withCurrentEntries:currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash atCurrentHeight:currentMasternodeList.height];
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

- (void)loadFileDistributedMasternodeLists {
    BOOL syncMasternodeLists = ([[DSOptionsManager sharedInstance] syncType] & DSSyncType_MasternodeList);
    BOOL useCheckpointMasternodeLists = [[DSOptionsManager sharedInstance] useCheckpointMasternodeLists];
    if (!syncMasternodeLists || !useCheckpointMasternodeLists) return;
    if (!self.currentMasternodeList) {
        DSCheckpoint *checkpoint = [self.chain lastCheckpointHavingMasternodeList];
        if (checkpoint && self.chain.lastTerminalBlockHeight >= checkpoint.height) {
            if (![self masternodeListForBlockHash:checkpoint.blockHash]) {
                [self processRequestFromFileForBlockHash:checkpoint.blockHash
                                              completion:^(BOOL success, DSMasternodeList *masternodeList) {
                                                  if (success && masternodeList) {
                                                      self.currentMasternodeList = masternodeList;
                                                  }
                                              }];
            }
        }
    }
}

- (DSMasternodeList *)loadMasternodeListAtBlockHash:(NSData *)blockHash withBlockHeightLookup:(uint32_t (^_Nullable)(UInt256 blockHash))blockHeightLookup {
    __block DSMasternodeList *masternodeList = nil;
    [self.managedObjectContext performBlockAndWait:^{
        DSMasternodeListEntity *masternodeListEntity = [DSMasternodeListEntity anyObjectInContext:self.managedObjectContext matching:@"block.chain == %@ && block.blockHash == %@", [self.chain chainEntityInContext:self.managedObjectContext], blockHash];
        NSMutableDictionary *simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary *quorumEntryPool = [NSMutableDictionary dictionary];

        masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy]
                                                                               quorumEntryPool:quorumEntryPool
                                                                         withBlockHeightLookup:blockHeightLookup];
        if (masternodeList) {
            [self.masternodeListsByBlockHash setObject:masternodeList forKey:blockHash];
            [self.masternodeListsBlockHashStubs removeObject:blockHash];
            DSLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries", masternodeList.height, uint256_hex(masternodeList.blockHash), (unsigned long)masternodeList.simplifiedMasternodeEntries.count);
        }
    }];
    return masternodeList;
}

- (void)wipeMasternodeInfo {
    [self.masternodeListsByBlockHash removeAllObjects];
    [self.masternodeListsBlockHashStubs removeAllObjects];
    [self.localMasternodesDictionaryByRegistrationTransactionHash removeAllObjects];
    self.currentMasternodeList = nil;
    self.masternodeListAwaitingQuorumValidation = nil;
    [self.masternodeListRetrievalQueue removeAllObjects];
    [self.masternodeListsInRetrieval removeAllObjects];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];
        [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];
    });
}

// MARK: - Masternode List Helpers

- (DSMasternodeList *)masternodeListForBlockHash:(UInt256)blockHash {
    return [self masternodeListForBlockHash:blockHash withBlockHeightLookup:nil];
}

- (DSMasternodeList *)masternodeListForBlockHash:(UInt256)blockHash withBlockHeightLookup:(uint32_t (^_Nullable)(UInt256 blockHash))blockHeightLookup {
    NSData *blockData = uint256_data(blockHash);
    DSMasternodeList *masternodeList = [self.masternodeListsByBlockHash objectForKey:blockData];
    if (!masternodeList && [self.masternodeListsBlockHashStubs containsObject:blockData]) {
        masternodeList = [self loadMasternodeListAtBlockHash:blockData withBlockHeightLookup:blockHeightLookup];
    }
    if (!masternodeList) {
        if (blockHeightLookup) {
            DSLog(@"No masternode list at %@ (%d)", uint256_reverse_hex(blockHash), blockHeightLookup(blockHash));
        } else {
            DSLog(@"No masternode list at %@", uint256_reverse_hex(blockHash));
        }
    }
    return masternodeList;
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
    if (self.chain.isMainnet && closestMasternodeList.height < 1088640 && blockHeight >= 1088640) return nil; //special mainnet case
    return closestMasternodeList;
}

// MARK: - Requesting Masternode List

- (void)addToMasternodeRetrievalQueue:(NSData *)masternodeBlockHashData {
    NSAssert(uint256_is_not_zero(masternodeBlockHashData.UInt256), @"the hash data must not be empty");
    [self.masternodeListRetrievalQueue addObject:masternodeBlockHashData];
    self.masternodeListRetrievalQueueMaxAmount = MAX(self.masternodeListRetrievalQueueMaxAmount, self.masternodeListRetrievalQueue.count);
    [self.masternodeListRetrievalQueue sortUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
        NSData *obj1BlockHash = (NSData *)obj1;
        NSData *obj2BlockHash = (NSData *)obj2;
        if ([self heightForBlockHash:obj1BlockHash.UInt256] < [self heightForBlockHash:obj2BlockHash.UInt256]) {
            return NSOrderedAscending;
        } else {
            return NSOrderedDescending;
        }
    }];
}

- (void)addToMasternodeRetrievalQueueArray:(NSArray *)masternodeBlockHashDataArray {
    NSMutableArray *nonEmptyBlockHashes = [NSMutableArray array];
    for (NSData *blockHashData in masternodeBlockHashDataArray) {
        NSAssert(uint256_is_not_zero(blockHashData.UInt256), @"We should not be adding an empty block hash");
        if (uint256_is_not_zero(blockHashData.UInt256)) {
            [nonEmptyBlockHashes addObject:blockHashData];
        }
    }
    [self.masternodeListRetrievalQueue addObjectsFromArray:nonEmptyBlockHashes];
    self.masternodeListRetrievalQueueMaxAmount = MAX(self.masternodeListRetrievalQueueMaxAmount, self.masternodeListRetrievalQueue.count);
    [self.masternodeListRetrievalQueue sortUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
        NSData *obj1BlockHash = (NSData *)obj1;
        NSData *obj2BlockHash = (NSData *)obj2;
        if ([self heightForBlockHash:obj1BlockHash.UInt256] < [self heightForBlockHash:obj2BlockHash.UInt256]) {
            return NSOrderedAscending;
        } else {
            return NSOrderedDescending;
        }
    }];
}

- (void)startTimeOutObserver {
    __block NSSet *masternodeListsInRetrieval = [self.masternodeListsInRetrieval copy];
    __block NSUInteger masternodeListCount = [self knownMasternodeListsCount];

    self.timeOutObserverTry++;
    __block uint16_t timeOutObserverTry = self.timeOutObserverTry;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * (self.timedOutAttempt + 1) * NSEC_PER_SEC)), self.chain.networkingQueue, ^{
        if (![self.masternodeListRetrievalQueue count]) return;
        if (self.timeOutObserverTry != timeOutObserverTry) return;
        NSMutableSet *leftToGet = [masternodeListsInRetrieval mutableCopy];
        [leftToGet intersectSet:self.masternodeListsInRetrieval];
        if (self.processingMasternodeListDiffHashes) {
            [leftToGet removeObject:self.processingMasternodeListDiffHashes];
        }
        if ((masternodeListCount == [self knownMasternodeListsCount]) && [masternodeListsInRetrieval isEqualToSet:leftToGet]) {
            //Nothing has changed
            DSLog(@"TimedOut");
            //timeout
            self.timedOutAttempt++;
            [self.peerManager.downloadPeer disconnect];
            [self.masternodeListsInRetrieval removeAllObjects];
            [self dequeueMasternodeListRequest];
        } else {
            [self startTimeOutObserver];
        }
    });
}

- (void)dequeueMasternodeListRequest {
    DSLog(@"Dequeued Masternode List Request");
    if (![self.masternodeListRetrievalQueue count]) {
        DSLog(@"No masternode lists in retrieval");
        [self.chain.chainManager chainFinishedSyncingMasternodeListsAndQuorums:self.chain];
        return;
    }
    if ([self.masternodeListsInRetrieval count]) {
        DSLog(@"A masternode list is already in retrieval");
        return;
    }
    if (!self.peerManager.downloadPeer || (self.peerManager.downloadPeer.status != DSPeerStatus_Connected)) {
        if (self.chain.chainManager.syncPhase != DSChainSyncPhase_Offline) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), self.chain.networkingQueue, ^{
                [self dequeueMasternodeListRequest];
            });
        }
        return;
    }

    NSMutableOrderedSet<NSData *> *masternodeListsToRetrieve = [self.masternodeListRetrievalQueue mutableCopy];

    for (NSData *blockHashData in masternodeListsToRetrieve) {
        NSUInteger pos = [masternodeListsToRetrieve indexOfObject:blockHashData];
        UInt256 blockHash = blockHashData.UInt256;

        //we should check the associated block still exists
        __block BOOL hasBlock = ([self.chain blockForBlockHash:blockHash] != nil);
        if (!hasBlock) {
            [self.managedObjectContext performBlockAndWait:^{
                hasBlock = !![DSMerkleBlockEntity countObjectsInContext:self.managedObjectContext matching:@"blockHash == %@", uint256_data(blockHash)];
            }];
        }
        if (!hasBlock && self.chain.isTestnet) {
            //We can trust insight if on testnet
            [DSMasternodeManager blockUntilAddInsight:blockHash forChain:self.chain];
            hasBlock = !![[self.chain insightVerifiedBlocksByHashDictionary] objectForKey:uint256_data(blockHash)];
        }
        if (hasBlock) {
            //there is the rare possibility we have the masternode list as a checkpoint, so lets first try that
            [self processRequestFromFileForBlockHash:blockHash
                                          completion:^(BOOL success, DSMasternodeList *masternodeList) {
                                              if (!success) {
                                                  //we need to go get it
                                                  UInt256 previousMasternodeAlreadyKnownBlockHash = [self closestKnownBlockHashForBlockHash:blockHash];
                                                  UInt256 previousMasternodeInQueueBlockHash = (pos ? [masternodeListsToRetrieve objectAtIndex:pos - 1].UInt256 : UINT256_ZERO);
                                                  uint32_t previousMasternodeAlreadyKnownHeight = [self heightForBlockHash:previousMasternodeAlreadyKnownBlockHash];
                                                  uint32_t previousMasternodeInQueueHeight = (pos ? [self heightForBlockHash:previousMasternodeInQueueBlockHash] : UINT32_MAX);
                                                  UInt256 previousBlockHash = pos ? (previousMasternodeAlreadyKnownHeight > previousMasternodeInQueueHeight ? previousMasternodeAlreadyKnownBlockHash : previousMasternodeInQueueBlockHash) : previousMasternodeAlreadyKnownBlockHash;

                                                  DSLog(@"Requesting masternode list and quorums from %u to %u (%@ to %@)", [self heightForBlockHash:previousBlockHash], [self heightForBlockHash:blockHash], uint256_reverse_hex(previousBlockHash), uint256_reverse_hex(blockHash));
                                                  NSAssert(([self heightForBlockHash:previousBlockHash] != UINT32_MAX) || uint256_is_zero(previousBlockHash), @"This block height should be known");
                                                  [self.peerManager.downloadPeer sendGetMasternodeListFromPreviousBlockHash:previousBlockHash forBlockHash:blockHash];
                                                  UInt512 concat = uint512_concat(previousBlockHash, blockHash);
                                                  [self.masternodeListsInRetrieval addObject:uint512_data(concat)];
                                              } else {
                                                  //we already had it
                                                  [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
                                              }
                                          }];
        } else {
            DSLog(@"Missing block (%@)", uint256_reverse_hex(blockHash));
            [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
        }
    }
    [self startTimeOutObserver];
}

- (void)getRecentMasternodeList:(NSUInteger)blocksAgo withSafetyDelay:(uint32_t)safetyDelay {
    @synchronized(self.masternodeListRetrievalQueue) {
        DSMerkleBlock *merkleBlock = [self.chain blockFromChainTip:blocksAgo];
        if ([self.masternodeListRetrievalQueue lastObject] && uint256_eq(merkleBlock.blockHash, [self.masternodeListRetrievalQueue lastObject].UInt256)) {
            //we are asking for the same as the last one
            return;
        }
        if ([self.masternodeListsByBlockHash.allKeys containsObject:uint256_data(merkleBlock.blockHash)]) {
            DSLog(@"Already have that masternode list %u", merkleBlock.height);
            return;
        }
        if ([self.masternodeListsBlockHashStubs containsObject:uint256_data(merkleBlock.blockHash)]) {
            DSLog(@"Already have that masternode list in stub %u", merkleBlock.height);
            return;
        }

        self.lastQueriedBlockHash = merkleBlock.blockHash;
        [self.masternodeListQueriesNeedingQuorumsValidated addObject:uint256_data(merkleBlock.blockHash)];
        DSLog(@"Getting masternode list %u", merkleBlock.height);
        BOOL emptyRequestQueue = ![self.masternodeListRetrievalQueue count];
        [self addToMasternodeRetrievalQueue:uint256_data(merkleBlock.blockHash)];
        if (emptyRequestQueue) {
            [self dequeueMasternodeListRequest];
        }
    }
}

- (void)getCurrentMasternodeListWithSafetyDelay:(uint32_t)safetyDelay {
    if (safetyDelay) {
        //the safety delay checks to see if this was called in the last n seconds.
        self.timeIntervalForMasternodeRetrievalSafetyDelay = [[NSDate date] timeIntervalSince1970];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safetyDelay * NSEC_PER_SEC)), self.chain.networkingQueue, ^{
            NSTimeInterval timeElapsed = [[NSDate date] timeIntervalSince1970] - self.timeIntervalForMasternodeRetrievalSafetyDelay;
            if (timeElapsed > safetyDelay) {
                [self getCurrentMasternodeListWithSafetyDelay:0];
            }
        });
    } else {
        [self getRecentMasternodeList:0 withSafetyDelay:safetyDelay];
    }
}

- (void)getMasternodeListsForBlockHashes:(NSOrderedSet *)blockHashes {
    @synchronized(self.masternodeListRetrievalQueue) {
        NSArray *orderedBlockHashes = [blockHashes sortedArrayUsingComparator:^NSComparisonResult(NSData *_Nonnull obj1, NSData *_Nonnull obj2) {
            uint32_t height1 = [self heightForBlockHash:obj1.UInt256];
            uint32_t height2 = [self heightForBlockHash:obj2.UInt256];
            return (height1 > height2) ? NSOrderedDescending : NSOrderedAscending;
        }];
        for (NSData *blockHash in orderedBlockHashes) {
            DSLog(@"adding retrieval of masternode list at height %u to queue (%@)", [self heightForBlockHash:blockHash.UInt256], blockHash.reverse.hexString);
        }
        [self addToMasternodeRetrievalQueueArray:orderedBlockHashes];
    }
}

- (BOOL)requestMasternodeListForBlockHeight:(uint32_t)blockHeight error:(NSError **)error {
    DSMerkleBlock *merkleBlock = [self.chain blockAtHeight:blockHeight];
    if (!merkleBlock) {
        if (error) {
            *error = [NSError errorWithDomain:@"DashSync" code:600 userInfo:@{NSLocalizedDescriptionKey: @"Unknown block"}];
        }
        return FALSE;
    }
    [self requestMasternodeListForBlockHash:merkleBlock.blockHash];
    return TRUE;
}

- (BOOL)requestMasternodeListForBlockHash:(UInt256)blockHash {
    self.lastQueriedBlockHash = blockHash;
    [self.masternodeListQueriesNeedingQuorumsValidated addObject:uint256_data(blockHash)];
    //this is safe
    [self getMasternodeListsForBlockHashes:[NSOrderedSet orderedSetWithObject:uint256_data(blockHash)]];
    [self dequeueMasternodeListRequest];
    return TRUE;
}

// MARK: - Deterministic Masternode List Sync

- (void)processRequestFromFileForBlockHash:(UInt256)blockHash completion:(void (^)(BOOL success, DSMasternodeList *masternodeList))completion {
    DSCheckpoint *checkpoint = [self.chain checkpointForBlockHash:blockHash];
    if (!checkpoint || !checkpoint.masternodeListName || [checkpoint.masternodeListName isEqualToString:@""]) {
        DSLog(@"No masternode list checkpoint found at height %u", [self heightForBlockHash:blockHash]);
        completion(NO, nil);
        return;
    }
    NSString *bundlePath = [[NSBundle bundleForClass:self.class] pathForResource:@"DashSync" ofType:@"bundle"];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *filePath = [bundle pathForResource:checkpoint.masternodeListName ofType:@"dat"];
    if (!filePath) {
        completion(NO, nil);
        return;
    }
    __block DSMerkleBlock *block = [self.chain blockForBlockHash:blockHash];
    NSData *message = [NSData dataWithContentsOfFile:filePath];
    [self processMasternodeDiffMessage:message
                    baseMasternodeList:nil
                             lastBlock:block
                    useInsightAsBackup:NO
                            completion:^(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists) {
                                if (!foundCoinbase || !rootMNListValid || !rootQuorumListValid || !validQuorums) {
                                    completion(NO, nil);
                                    DSLog(@"Invalid File for block at height %u with merkleRoot %@", block.height, uint256_hex(block.merkleRoot));
                                    return;
                                }

                                //valid Coinbase might be false if no merkle block
                                if (block && !validCoinbase) {
                                    DSLog(@"Invalid Coinbase for block at height %u with merkleRoot %@", block.height, uint256_hex(block.merkleRoot));
                                    completion(NO, nil);
                                    return;
                                }
                                NSData *blockHashData = uint256_data(masternodeList.blockHash);
                                if (!self.masternodeListsByBlockHash[blockHashData] &&
                                    ![self.masternodeListsBlockHashStubs containsObject:blockHashData]) {
                                    //in rare race conditions this might already exist

                                    NSArray *updatedSimplifiedMasternodeEntries = [addedMasternodes.allValues arrayByAddingObjectsFromArray:modifiedMasternodes.allValues];
                                    [self.chain updateAddressUsageOfSimplifiedMasternodeEntries:updatedSimplifiedMasternodeEntries];

                                    [self saveMasternodeList:masternodeList
                                        havingModifiedMasternodes:modifiedMasternodes
                                                     addedQuorums:addedQuorums
                                                       completion:^(NSError *error) {
                                                           if (!KEEP_OLD_QUORUMS && uint256_eq(self.lastQueriedBlockHash, masternodeList.blockHash)) {
                                                               [self removeOldMasternodeLists];
                                                           }

                                                           if (![self.masternodeListRetrievalQueue count]) {
                                                               [self.chain.chainManager.transactionManager checkInstantSendLocksWaitingForQuorums];
                                                               [self.chain.chainManager.transactionManager checkChainLocksWaitingForQuorums];
                                                           }
                                                           completion(YES, masternodeList);
                                                       }];
                                }
                            }];
}


#define TEST_RANDOM_ERROR_IN_MASTERNODE_DIFF 0

- (void)processMasternodeDiffMessage:(NSData *)message
                  baseMasternodeList:(DSMasternodeList *)baseMasternodeList
                           lastBlock:(DSBlock *)lastBlock
                  useInsightAsBackup:(BOOL)useInsightAsBackup
                          completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists))completion {
    [DSMasternodeManager processMasternodeDiffMessage:message
        baseMasternodeList:baseMasternodeList
        masternodeListLookup:^DSMasternodeList *(UInt256 blockHash) {
            return [self masternodeListForBlockHash:blockHash];
        }
        lastBlock:lastBlock
        useInsightAsBackup:useInsightAsBackup
        onChain:self.chain
        blockHeightLookup:^uint32_t(UInt256 blockHash) {
            return [self heightForBlockHash:blockHash];
        }
        completion:completion];
}

+ (void)processMasternodeDiffMessage:(NSData *)message
                  baseMasternodeList:(DSMasternodeList *)baseMasternodeList
                masternodeListLookup:(DSMasternodeList * (^)(UInt256 blockHash))masternodeListLookup
                           lastBlock:(DSBlock *)lastBlock
                  useInsightAsBackup:(BOOL)useInsightAsBackup
                             onChain:(DSChain *)chain
                   blockHeightLookup:(uint32_t (^)(UInt256 blockHash))blockHeightLookup
                          completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists))completion {
    void (^failureBlock)(void) = ^{
        completion(NO, NO, NO, NO, NO, nil, nil, nil, nil, nil);
    };

    NSUInteger length = message.length;
    NSUInteger offset = 0;

    if (length - offset < 32) {
        failureBlock();
        return;
    }
    __unused UInt256 baseBlockHash = [message UInt256AtOffset:offset];
    offset += 32;

    if (length - offset < 32) {
        failureBlock();
        return;
    }
    UInt256 blockHash = [message UInt256AtOffset:offset];
    offset += 32;

    if (length - offset < 4) {
        failureBlock();
        return;
    }
    uint32_t totalTransactions = [message UInt32AtOffset:offset];
    offset += 4;

    if (length - offset < 1) {
        failureBlock();
        return;
    }

    NSNumber *merkleHashCountLength;
    NSUInteger merkleHashCount = (NSUInteger)[message varIntAtOffset:offset length:&merkleHashCountLength] * sizeof(UInt256);
    offset += [merkleHashCountLength unsignedLongValue];


    NSData *merkleHashes = [message subdataWithRange:NSMakeRange(offset, merkleHashCount)];
    offset += merkleHashCount;

    NSNumber *merkleFlagCountLength;
    NSUInteger merkleFlagCount = (NSUInteger)[message varIntAtOffset:offset length:&merkleFlagCountLength];
    offset += [merkleFlagCountLength unsignedLongValue];


    NSData *merkleFlags = [message subdataWithRange:NSMakeRange(offset, merkleFlagCount)];
    offset += merkleFlagCount;


    DSCoinbaseTransaction *coinbaseTransaction = (DSCoinbaseTransaction *)[DSTransactionFactory transactionWithMessage:[message subdataWithRange:NSMakeRange(offset, message.length - offset)] onChain:chain];
    if (![coinbaseTransaction isMemberOfClass:[DSCoinbaseTransaction class]]) return;
    offset += coinbaseTransaction.payloadOffset;

    if (length - offset < 1) {
        failureBlock();
        return;
    }
    NSNumber *deletedMasternodeCountLength;
    uint64_t deletedMasternodeCount = [message varIntAtOffset:offset length:&deletedMasternodeCountLength];
    offset += [deletedMasternodeCountLength unsignedLongValue];

    NSMutableArray *deletedMasternodeHashes = [NSMutableArray array];

    while (deletedMasternodeCount >= 1) {
        if (length - offset < 32) {
            failureBlock();
            return;
        }
        [deletedMasternodeHashes addObject:[NSData dataWithUInt256:[message UInt256AtOffset:offset]].reverse];
        offset += 32;
        deletedMasternodeCount--;
    }

    if (length - offset < 1) {
        failureBlock();
        return;
    }
    NSNumber *addedMasternodeCountLength;
    uint64_t addedMasternodeCount = [message varIntAtOffset:offset length:&addedMasternodeCountLength];
    offset += [addedMasternodeCountLength unsignedLongValue];

    NSMutableDictionary *addedOrModifiedMasternodes = [NSMutableDictionary dictionary];

    uint32_t blockHeight = blockHeightLookup(blockHash);

    while (addedMasternodeCount >= 1) {
        if (length - offset < [DSSimplifiedMasternodeEntry payloadLength]) return;
        NSData *data = [message subdataWithRange:NSMakeRange(offset, [DSSimplifiedMasternodeEntry payloadLength])];
        DSSimplifiedMasternodeEntry *simplifiedMasternodeEntry = [DSSimplifiedMasternodeEntry simplifiedMasternodeEntryWithData:data atBlockHeight:blockHeight onChain:chain];
        NSData *key = [NSData dataWithUInt256:simplifiedMasternodeEntry.providerRegistrationTransactionHash].reverse;
        [addedOrModifiedMasternodes setObject:simplifiedMasternodeEntry forKey:key];
        offset += [DSSimplifiedMasternodeEntry payloadLength];
        addedMasternodeCount--;
    }

    NSMutableDictionary *addedMasternodes = [addedOrModifiedMasternodes mutableCopy];
    NSMutableSet *modifiedMasternodeKeys;
    if (baseMasternodeList) {
        //Do we need to use reversedRegistrationTransactionHashes or only hashes from white list?
        [addedMasternodes removeObjectsForKeys:baseMasternodeList.reversedRegistrationTransactionHashes];
        modifiedMasternodeKeys = [NSMutableSet setWithArray:[addedOrModifiedMasternodes allKeys]];
        [modifiedMasternodeKeys intersectSet:[NSSet setWithArray:baseMasternodeList.reversedRegistrationTransactionHashes]];
    } else {
        modifiedMasternodeKeys = [NSMutableSet set];
    }
    NSMutableDictionary *modifiedMasternodes = [NSMutableDictionary dictionary];
    for (NSData *data in modifiedMasternodeKeys) {
        [modifiedMasternodes setObject:addedOrModifiedMasternodes[data] forKey:data];
    }

    NSMutableDictionary *deletedQuorums = [NSMutableDictionary dictionary];
    NSMutableDictionary *addedQuorums = [NSMutableDictionary dictionary];

    BOOL quorumsActive = (coinbaseTransaction.coinbaseTransactionVersion >= 2);

    BOOL validQuorums = TRUE;

    NSMutableOrderedSet *neededMasternodeLists = [NSMutableOrderedSet orderedSet]; //if quorums are not active this stays empty

    if (quorumsActive) {
        if (length - offset < 1) {
            failureBlock();
            return;
        }
        NSNumber *deletedQuorumsCountLength;
        uint64_t deletedQuorumsCount = [message varIntAtOffset:offset length:&deletedQuorumsCountLength];
        offset += [deletedQuorumsCountLength unsignedLongValue];

        while (deletedQuorumsCount >= 1) {
            if (length - offset < 33) {
                failureBlock();
                return;
            }
            uint8_t llmqType = [message UInt8AtOffset:offset];
            UInt256 llmqHash = [message UInt256AtOffset:offset + 1];
            NSData *llmqHashData = [NSData dataWithUInt256:llmqHash];
            NSMutableArray *mutableLLMQArray = [deletedQuorums objectForKey:@(llmqType)];
            if (mutableLLMQArray) {
                [mutableLLMQArray addObject:llmqHashData];
            } else {
                [deletedQuorums setObject:[NSMutableArray arrayWithObject:llmqHashData] forKey:@(llmqType)];
            }
            offset += 33;
            deletedQuorumsCount--;
        }

        if (length - offset < 1) {
            failureBlock();
            return;
        }
        NSNumber *addedQuorumsCountLength;
        uint64_t addedQuorumsCount = [message varIntAtOffset:offset length:&addedQuorumsCountLength];
        offset += [addedQuorumsCountLength unsignedLongValue];

        while (addedQuorumsCount >= 1) {
            DSQuorumEntry *potentialQuorumEntry = [DSQuorumEntry potentialQuorumEntryWithData:message dataOffset:(uint32_t)offset onChain:chain];
            UInt256 entryQuorumHash = potentialQuorumEntry.quorumHash;
            DSLLMQType llmqType = potentialQuorumEntry.llmqType;
            if (potentialQuorumEntry.shouldProcessQuorum) {
                DSMasternodeList *quorumMasternodeList = masternodeListLookup(entryQuorumHash);
                if (quorumMasternodeList) {
                    validQuorums &= [potentialQuorumEntry validateWithMasternodeList:quorumMasternodeList blockHeightLookup:blockHeightLookup];
                    if (!validQuorums) {
                        DSLog(@"Invalid Quorum Found For Quorum at height %d", quorumMasternodeList.height);
                    }
                } else {
                    if (blockHeightLookup(entryQuorumHash) != UINT32_MAX) {
                        [neededMasternodeLists addObject:uint256_data(entryQuorumHash)];
                    } else {
                        if (useInsightAsBackup) {
                            //We can trust insight if on testnet
                            [DSMasternodeManager blockUntilAddInsight:entryQuorumHash forChain:chain];
                            if (blockHeightLookup(entryQuorumHash) != UINT32_MAX) {
                                [neededMasternodeLists addObject:uint256_data(entryQuorumHash)];
                            } else {
                                DSLog(@"Quorum masternode list not found and block not available");
                            }
                        } else {
                            DSLog(@"Quorum masternode list not found and block not available");
                        }
                    }
                }
            }
            NSData *entryQuorumHashData = [NSData dataWithUInt256:entryQuorumHash];
            NSMutableDictionary *mutableLLMQDictionary = [addedQuorums objectForKey:@(llmqType)];
            if (!mutableLLMQDictionary) {
                [addedQuorums setObject:[NSMutableDictionary dictionaryWithObject:potentialQuorumEntry forKey:entryQuorumHashData] forKey:@(llmqType)];
            } else {
                [mutableLLMQDictionary setObject:potentialQuorumEntry forKey:entryQuorumHashData];
            }
            offset += potentialQuorumEntry.length;
            addedQuorumsCount--;
        }
    }

    DSMasternodeList *masternodeList = [DSMasternodeList masternodeListAtBlockHash:blockHash atBlockHeight:blockHeightLookup(blockHash) fromBaseMasternodeList:baseMasternodeList addedMasternodes:addedMasternodes removedMasternodeHashes:deletedMasternodeHashes modifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums removedQuorumHashesByType:deletedQuorums onChain:chain];

    BOOL rootMNListValid = uint256_eq(coinbaseTransaction.merkleRootMNList, [masternodeList masternodeMerkleRootWithBlockHeightLookup:blockHeightLookup]);

    if (!rootMNListValid) {
        DSLog(@"Masternode Merkle root not valid for DML on block %d version %d (%@ wanted - %@ calculated)", coinbaseTransaction.height, coinbaseTransaction.version, uint256_hex(coinbaseTransaction.merkleRootMNList), uint256_hex(masternodeList.masternodeMerkleRoot));
        int i = 0;
        for (NSString *string in [[masternodeList hashesForMerkleRootWithBlockHeightLookup:blockHeightLookup] transformToArrayOfHexStrings]) {
            DSLog(@"Hash %i is %@", i++, string);
        }

#if SAVE_MASTERNODE_ERROR_TO_FILE
        [DSMasternodeManager writeToLog:blockHeightLookup
                       inMasternodeList:masternodeList];
#endif
#if SAVE_MASTERNODE_NO_ERROR_TO_FILE
    } else {
        [DSMasternodeManager writeToLog:blockHeightLookup inMasternodeList:masternodeList];
#endif
    }

    BOOL rootQuorumListValid = TRUE;

    if (quorumsActive) {
        rootQuorumListValid = uint256_eq(coinbaseTransaction.merkleRootLLMQList, masternodeList.quorumMerkleRoot);

        if (!rootQuorumListValid) {
            DSLog(@"Quorum Merkle root not valid for DML on block %d version %d (%@ wanted - %@ calculated)", coinbaseTransaction.height, coinbaseTransaction.version, uint256_hex(coinbaseTransaction.merkleRootLLMQList), uint256_hex(masternodeList.quorumMerkleRoot));
        }
    }

    //we need to check that the coinbase is in the transaction hashes we got back
    UInt256 coinbaseHash = coinbaseTransaction.txHash;
    BOOL foundCoinbase = FALSE;
    for (int i = 0; i < merkleHashes.length; i += 32) {
        UInt256 randomTransactionHash = [merkleHashes UInt256AtOffset:i];
        if (uint256_eq(coinbaseHash, randomTransactionHash)) {
            foundCoinbase = TRUE;
            break;
        }
    }

    //we also need to check that the coinbase is in the merkle block
    DSMerkleTree *merkleTree = [[DSMerkleTree alloc] initWithHashes:merkleHashes flags:merkleFlags treeElementCount:totalTransactions hashFunction:DSMerkleTreeHashFunction_SHA256_2];
    BOOL validCoinbase = [merkleTree merkleTreeHasRoot:lastBlock.merkleRoot];

#if TEST_RANDOM_ERROR_IN_MASTERNODE_DIFF
    //test random errors
    uint32_t chance = 20; //chance is 1/10

    completion((arc4random_uniform(chance) != 0) && foundCoinbase, (arc4random_uniform(chance) != 0) && validCoinbase, (arc4random_uniform(chance) != 0) && rootMNListValid, (arc4random_uniform(chance) != 0) && rootQuorumListValid, (arc4random_uniform(chance) != 0) && validQuorums, masternodeList, addedMasternodes, modifiedMasternodes, addedQuorums, neededMasternodeLists);
#else

    //normal completion
    completion(foundCoinbase, validCoinbase, rootMNListValid, rootQuorumListValid, validQuorums, masternodeList, addedMasternodes, modifiedMasternodes, addedQuorums, neededMasternodeLists);

#endif
}

+ (void)blockUntilAddInsight:(UInt256)blockHash forChain:(DSChain *)chain {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[DSInsightManager sharedInstance] blockForBlockHash:uint256_reverse(blockHash)
                                                 onChain:chain
                                              completion:^(DSBlock *_Nullable block, NSError *_Nullable error) {
                                                  if (!error && block) {
                                                      [chain addInsightVerifiedBlock:block forBlockHash:blockHash];
                                                  }
                                                  dispatch_semaphore_signal(sem);
                                              }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

+ (void)writeToLog:(uint32_t (^)(UInt256 blockHash))blockHeightLookup inMasternodeList:(DSMasternodeList *)masternodeList {
    UInt256 blockHash = [masternodeList blockHash];
    uint32_t height = blockHeightLookup(blockHash);
    if (height == UINT32_MAX) {
        DSLog(@"Block height lookup queried an unknown block %@", uint256_hex(blockHash));
        return; //this should never happen
    }
    NSMutableData *message = [NSMutableData data];
    NSArray *proTxHashes = [masternodeList providerTxOrderedHashes];
    for (NSData *proTxHash in proTxHashes) {
        DSSimplifiedMasternodeEntry *entry = [masternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash objectForKey:proTxHash];
        NSData *hashData = uint256_data([entry simplifiedMasternodeEntryHashAtBlockHeight:height]);
        NSString *line = [NSString stringWithFormat:@"%@ -> %@\n", [proTxHash hexString], [hashData hexString]];
        [message appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *dataPath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"MNL_SME_ERROR_%d.txt", masternodeList.height]];
    // Save it into file system
    [message writeToFile:dataPath atomically:YES];
}

- (void)peer:(DSPeer *)peer relayedMasternodeDiffMessage:(NSData *)message {
#if LOG_MASTERNODE_DIFF
    DSFullLog(@"Logging masternode DIFF message %@", message.hexString);
    DSLog(@"Logging masternode DIFF message hash %@", [NSData dataWithUInt256:message.SHA256].hexString);
#endif

    self.timedOutAttempt = 0;

    NSUInteger length = message.length;
    NSUInteger offset = 0;

    if (length - offset < 32) return;
    UInt256 baseBlockHash = [message UInt256AtOffset:offset];
    offset += 32;

    if (length - offset < 32) return;
    UInt256 blockHash = [message UInt256AtOffset:offset];
    offset += 32;

#if SAVE_MASTERNODE_DIFF_TO_FILE
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *dataPath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"MNL_%@_%@.dat", @([self heightForBlockHash:baseBlockHash]), @([self heightForBlockHash:blockHash])]];

    // Save it into file system
    [message writeToFile:dataPath atomically:YES];
#endif

    NSData *blockHashData = uint256_data(blockHash);

    UInt512 concat = uint512_concat(baseBlockHash, blockHash);
    NSData *blockHashDiffsData = uint512_data(concat);

    if (![self.masternodeListsInRetrieval containsObject:blockHashDiffsData]) {
        NSMutableArray *masternodeListsInRetrievalStrings = [NSMutableArray array];
        for (NSData *masternodeListInRetrieval in self.masternodeListsInRetrieval) {
            [masternodeListsInRetrievalStrings addObject:masternodeListInRetrieval.hexString];
        }
        DSLog(@"A masternode list (%@) was received that is not set to be retrieved (%@)", blockHashDiffsData.hexString, [masternodeListsInRetrievalStrings componentsJoinedByString:@", "]);
        return;
    }

    [self.masternodeListsInRetrieval removeObject:blockHashDiffsData];

    if ([self.masternodeListsByBlockHash objectForKey:blockHashData]) {
        //we already have this
        DSLog(@"We already have this masternodeList %@ (%u)", blockHashData.reverse.hexString, [self heightForBlockHash:blockHash]);
        return; //no need to do anything more
    }

    if ([self.masternodeListsBlockHashStubs containsObject:blockHashData]) {
        //we already have this
        DSLog(@"We already have a stub for %@ (%u)", blockHashData.reverse.hexString, [self heightForBlockHash:blockHash]);
        return; //no need to do anything more
    }

    DSLog(@"relayed masternode diff with baseBlockHash %@ (%u) blockHash %@ (%u)", uint256_reverse_hex(baseBlockHash), [self heightForBlockHash:baseBlockHash], blockHashData.reverse.hexString, [self heightForBlockHash:blockHash]);

    DSMasternodeList *baseMasternodeList = [self masternodeListForBlockHash:baseBlockHash];

    if (!baseMasternodeList && !uint256_eq(self.chain.genesisHash, baseBlockHash) && uint256_is_not_zero(baseBlockHash)) {
        //this could have been deleted in the meantime, if so rerequest
        [self issueWithMasternodeListFromPeer:peer];
        DSLog(@"No base masternode list");
        return;
    }
    DSBlock *lastBlock = nil;
    if ([self.chain heightForBlockHash:blockHash]) {
        lastBlock = [[peer.chain terminalBlocks] objectForKey:uint256_obj(blockHash)];
        if (!lastBlock && [peer.chain allowInsightBlocksForVerification]) {
            lastBlock = [[peer.chain insightVerifiedBlocksByHashDictionary] objectForKey:uint256_data(blockHash)];
            if (!lastBlock && peer.chain.isTestnet) {
                //We can trust insight if on testnet
                [DSMasternodeManager blockUntilAddInsight:blockHash forChain:peer.chain];
                lastBlock = [[peer.chain insightVerifiedBlocksByHashDictionary] objectForKey:uint256_data(blockHash)];
            }
        }
    } else {
        lastBlock = [peer.chain recentTerminalBlockForBlockHash:blockHash];
    }


    if (!lastBlock) {
        [self issueWithMasternodeListFromPeer:peer];
        DSLog(@"Last Block missing");
        return;
    }

    self.processingMasternodeListDiffHashes = blockHashDiffsData;

    // We can use insight as backup if we are on testnet, we shouldn't otherwise.
    [self processMasternodeDiffMessage:message
                    baseMasternodeList:baseMasternodeList
                             lastBlock:lastBlock
                    useInsightAsBackup:self.chain.isTestnet
                            completion:^(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists) {
                                if (![self.masternodeListRetrievalQueue containsObject:uint256_data(masternodeList.blockHash)]) {
                                    //We most likely wiped data in the meantime
                                    [self.masternodeListsInRetrieval removeAllObjects];
                                    [self dequeueMasternodeListRequest];
                                    return;
                                }

                                if (foundCoinbase && validCoinbase && rootMNListValid && rootQuorumListValid && validQuorums) {
                                    DSLog(@"Valid masternode list found at height %u", [self heightForBlockHash:blockHash]);
                                    //yay this is the correct masternode list verified deterministically for the given block

                                    if ([neededMissingMasternodeLists count] && [self.masternodeListQueriesNeedingQuorumsValidated containsObject:uint256_data(blockHash)]) {
                                        DSLog(@"Last masternode list is missing previous masternode lists for quorum validation");

                                        self.processingMasternodeListDiffHashes = nil;

                                        //This is the current one, get more previous masternode lists we need to verify quorums

                                        self.masternodeListAwaitingQuorumValidation = masternodeList;
                                        [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
                                        NSMutableOrderedSet *neededMasternodeLists = [neededMissingMasternodeLists mutableCopy];
                                        [neededMasternodeLists addObject:uint256_data(blockHash)]; //also get the current one again
                                        [self getMasternodeListsForBlockHashes:neededMasternodeLists];
                                        [self dequeueMasternodeListRequest];
                                    } else {
                                        [self processValidMasternodeList:masternodeList havingAddedMasternodes:addedMasternodes modifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums];


                                        NSAssert([self.masternodeListRetrievalQueue containsObject:uint256_data(masternodeList.blockHash)], @"This should still be here");

                                        self.processingMasternodeListDiffHashes = nil;

                                        [self.masternodeListRetrievalQueue removeObject:uint256_data(masternodeList.blockHash)];
                                        [self dequeueMasternodeListRequest];

                                        //check for instant send locks that were awaiting a quorum

                                        if (![self.masternodeListRetrievalQueue count]) {
                                            [self.chain.chainManager.transactionManager checkInstantSendLocksWaitingForQuorums];
                                            [self.chain.chainManager.transactionManager checkChainLocksWaitingForQuorums];
                                        }

                                        [[NSUserDefaults standardUserDefaults] removeObjectForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
                                    }
                                } else {
                                    if (!foundCoinbase) DSLog(@"Did not find coinbase at height %u", [self heightForBlockHash:blockHash]);
                                    if (!validCoinbase) DSLog(@"Coinbase not valid at height %u", [self heightForBlockHash:blockHash]);
                                    if (!rootMNListValid) DSLog(@"rootMNListValid not valid at height %u", [self heightForBlockHash:blockHash]);
                                    if (!rootQuorumListValid) DSLog(@"rootQuorumListValid not valid at height %u", [self heightForBlockHash:blockHash]);
                                    if (!validQuorums) DSLog(@"validQuorums not valid at height %u", [self heightForBlockHash:blockHash]);

                                    self.processingMasternodeListDiffHashes = nil;

                                    [self issueWithMasternodeListFromPeer:peer];
                                }
                            }];
}

- (void)processValidMasternodeList:(DSMasternodeList *)masternodeList havingAddedMasternodes:(NSDictionary *)addedMasternodes modifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums {
    if (uint256_eq(self.lastQueriedBlockHash, masternodeList.blockHash)) {
        //this is now the current masternode list
        self.currentMasternodeList = masternodeList;
    }
    if (uint256_eq(self.masternodeListAwaitingQuorumValidation.blockHash, masternodeList.blockHash)) {
        self.masternodeListAwaitingQuorumValidation = nil;
    }
    if (!self.masternodeListsByBlockHash[uint256_data(masternodeList.blockHash)] && ![self.masternodeListsBlockHashStubs containsObject:uint256_data(masternodeList.blockHash)]) {
        //in rare race conditions this might already exist

        NSArray *updatedSimplifiedMasternodeEntries = [addedMasternodes.allValues arrayByAddingObjectsFromArray:modifiedMasternodes.allValues];
        [self.chain updateAddressUsageOfSimplifiedMasternodeEntries:updatedSimplifiedMasternodeEntries];

        [self saveMasternodeList:masternodeList
            havingModifiedMasternodes:modifiedMasternodes
                         addedQuorums:addedQuorums];
    }

    if (!KEEP_OLD_QUORUMS && uint256_eq(self.lastQueriedBlockHash, masternodeList.blockHash)) {
        [self removeOldMasternodeLists];
    }
}

- (BOOL)hasMasternodeListCurrentlyBeingSaved {
    return !!self.masternodeListCurrentlyBeingSavedCount;
}

- (void)saveMasternodeList:(DSMasternodeList *)masternodeList havingModifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums {
    [self saveMasternodeList:masternodeList
        havingModifiedMasternodes:modifiedMasternodes
                     addedQuorums:addedQuorums
                       completion:^(NSError *error) {
                           self.masternodeListCurrentlyBeingSavedCount--;
                           if (error) {
                               if ([self.masternodeListRetrievalQueue count]) { //if it is 0 then we most likely have wiped chain info
                                   [self wipeMasternodeInfo];
                                   dispatch_async(self.chain.networkingQueue, ^{
                                       [self getCurrentMasternodeListWithSafetyDelay:0];
                                   });
                               }
                           }
                       }];
}

- (void)saveMasternodeList:(DSMasternodeList *)masternodeList havingModifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums completion:(void (^)(NSError *error))completion {
    [self.masternodeListsByBlockHash setObject:masternodeList forKey:uint256_data(masternodeList.blockHash)];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];

        [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];
    });
    //We will want to create unknown blocks if they came from insight
    BOOL createUnknownBlocks = masternodeList.chain.allowInsightBlocksForVerification;
    self.masternodeListCurrentlyBeingSavedCount++;
    //This will create a queue for masternodes to be saved without blocking the networking queue
    dispatch_async(self.masternodeSavingQueue, ^{
        [DSMasternodeManager saveMasternodeList:masternodeList
                                        toChain:self.chain
                      havingModifiedMasternodes:modifiedMasternodes
                                   addedQuorums:addedQuorums
                            createUnknownBlocks:createUnknownBlocks
                                      inContext:self.managedObjectContext
                                     completion:completion];
    });
}

+ (void)saveMasternodeList:(DSMasternodeList *)masternodeList toChain:(DSChain *)chain havingModifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums createUnknownBlocks:(BOOL)createUnknownBlocks inContext:(NSManagedObjectContext *)context completion:(void (^)(NSError *error))completion {
    DSLog(@"Queued saving MNL at height %u", masternodeList.height);
    [context performBlockAndWait:^{
        //masternodes
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

            //this is the initial list sync so lets speed things up a little bit with some optimizations
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
                    //it was updated in this masternode list
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
            //A quorum is on a block that can only have one masternode list.
            //A block can have one quorum of each type.
            //A quorum references the masternode list by it's block
            //we need to check if this masternode list is being referenced by a quorum using the inverse of quorum.block.masternodeList

            [self.managedObjectContext deleteObject:masternodeListEntity];
            [self.masternodeListsByBlockHash removeObjectForKey:masternodeListEntity.block.blockHash];
        }
        if (removedItems) {
            //Now we should delete old quorums
            //To do this, first get the last 24 active masternode lists
            //Then check for quorums not referenced by them, and delete those

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
    //this serves both for cleanup, but also for initial migration

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

- (void)issueWithMasternodeListFromPeer:(DSPeer *)peer {
    [self.peerManager peerMisbehaving:peer errorMessage:@"Issue with Deterministic Masternode list"];

    NSArray *faultyPeers = [[NSUserDefaults standardUserDefaults] arrayForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];

    if (faultyPeers.count >= MAX_FAULTY_DML_PEERS) {
        DSLog(@"Exceeded max failures for masternode list, starting from scratch");
        //no need to remove local masternodes
        [self.masternodeListRetrievalQueue removeAllObjects];

        [self.managedObjectContext performBlockAndWait:^{
            DSChainEntity *chainEntity = [self.chain chainEntityInContext:self.managedObjectContext];
            [DSSimplifiedMasternodeEntryEntity deleteAllOnChainEntity:chainEntity];
            [DSQuorumEntryEntity deleteAllOnChainEntity:chainEntity];
            [DSMasternodeListEntity deleteAllOnChainEntity:chainEntity];
            [self.managedObjectContext ds_save];
        }];

        [self.masternodeListsByBlockHash removeAllObjects];
        [self.masternodeListsBlockHashStubs removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];

        [self getCurrentMasternodeListWithSafetyDelay:0];
    } else {
        if (!faultyPeers) {
            faultyPeers = @[peer.location];
        } else {
            if (![faultyPeers containsObject:peer.location]) {
                faultyPeers = [faultyPeers arrayByAddingObject:peer.location];
            }
        }
        [[NSUserDefaults standardUserDefaults] setObject:faultyPeers
                                                  forKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
        [self dequeueMasternodeListRequest];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDiffValidationErrorNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: self.chain}];
    });
}

// MARK: - Quorums

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

- (DSQuorumEntry *)quorumEntryForChainLockRequestID:(UInt256)requestID withBlockHeightOffset:(uint32_t)blockHeightOffset {
    DSMerkleBlock *merkleBlock = [self.chain blockFromChainTip:blockHeightOffset];
    return [self quorumEntryForChainLockRequestID:requestID forMerkleBlock:merkleBlock];
}

- (DSQuorumEntry *)quorumEntryForChainLockRequestID:(UInt256)requestID forBlockHeight:(uint32_t)blockHeight {
    DSMerkleBlock *merkleBlock = [self.chain blockAtHeight:blockHeight];
    return [self quorumEntryForChainLockRequestID:requestID forMerkleBlock:merkleBlock];
}

- (DSQuorumEntry *)quorumEntryForPlatformHavingQuorumHash:(UInt256)quorumHash forBlockHeight:(uint32_t)blockHeight {
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
    DSMasternodeList *masternodeList = [self masternodeListForBlockHash:block.blockHash];
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

// MARK: - Meta information

- (void)checkPingTimesForCurrentMasternodeListInContext:(NSManagedObjectContext *)context withCompletion:(void (^)(NSMutableDictionary<NSData *, NSNumber *> *pingTimes, NSMutableDictionary<NSData *, NSError *> *errors))completion {
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

// MARK: - Local Masternodes

- (DSLocalMasternode *)createNewMasternodeWithSocketAddress:(DSSocketAddress)socketAddress inWallet:(DSWallet *)wallet {
    NSParameterAssert(wallet);
    return [self createNewMasternodeWithSocketAddress:socketAddress inFundsWallet:wallet inOperatorWallet:wallet inOwnerWallet:wallet inVotingWallet:wallet];
}

- (DSLocalMasternode *)createNewMasternodeWithSocketAddress:(DSSocketAddress)socketAddress inFundsWallet:(DSWallet *)fundsWallet inOperatorWallet:(DSWallet *)operatorWallet inOwnerWallet:(DSWallet *)ownerWallet inVotingWallet:(DSWallet *)votingWallet {
    return [[DSLocalMasternode alloc] initWithSocketAddress:socketAddress inFundsWallet:fundsWallet inOperatorWallet:operatorWallet inOwnerWallet:ownerWallet inVotingWallet:votingWallet];
}

- (DSLocalMasternode *)createNewMasternodeWithSocketAddress:(DSSocketAddress)socketAddress inFundsWallet:(DSWallet *_Nullable)fundsWallet fundsWalletIndex:(uint32_t)fundsWalletIndex inOperatorWallet:(DSWallet *_Nullable)operatorWallet operatorWalletIndex:(uint32_t)operatorWalletIndex inOwnerWallet:(DSWallet *_Nullable)ownerWallet ownerWalletIndex:(uint32_t)ownerWalletIndex inVotingWallet:(DSWallet *_Nullable)votingWallet votingWalletIndex:(uint32_t)votingWalletIndex {
    return [[DSLocalMasternode alloc] initWithSocketAddress:socketAddress inFundsWallet:fundsWallet fundsWalletIndex:fundsWalletIndex inOperatorWallet:operatorWallet operatorWalletIndex:operatorWalletIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerWalletIndex inVotingWallet:votingWallet votingWalletIndex:votingWalletIndex];
}

- (DSLocalMasternode *)createNewMasternodeWithSocketAddress:(DSSocketAddress)socketAddress inFundsWallet:(DSWallet *_Nullable)fundsWallet fundsWalletIndex:(uint32_t)fundsWalletIndex inOperatorWallet:(DSWallet *_Nullable)operatorWallet operatorWalletIndex:(uint32_t)operatorWalletIndex operatorPublicKey:(DSBLSKey *)operatorPublicKey inOwnerWallet:(DSWallet *_Nullable)ownerWallet ownerWalletIndex:(uint32_t)ownerWalletIndex ownerPrivateKey:(DSECDSAKey *)ownerPrivateKey inVotingWallet:(DSWallet *_Nullable)votingWallet votingWalletIndex:(uint32_t)votingWalletIndex votingKey:(DSECDSAKey *)votingKey {
    DSLocalMasternode *localMasternode = [[DSLocalMasternode alloc] initWithSocketAddress:socketAddress inFundsWallet:fundsWallet fundsWalletIndex:fundsWalletIndex inOperatorWallet:operatorWallet operatorWalletIndex:operatorWalletIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerWalletIndex inVotingWallet:votingWallet votingWalletIndex:votingWalletIndex];

    if (operatorWalletIndex == UINT32_MAX && operatorPublicKey) {
        [localMasternode forceOperatorPublicKey:operatorPublicKey];
    }

    if (ownerWalletIndex == UINT32_MAX && ownerPrivateKey) {
        [localMasternode forceOwnerPrivateKey:ownerPrivateKey];
    }

    if (votingWalletIndex == UINT32_MAX && votingKey) {
        [localMasternode forceVotingKey:votingKey];
    }

    return localMasternode;
}

- (DSLocalMasternode *)localMasternodeFromSimplifiedMasternodeEntry:(DSSimplifiedMasternodeEntry *)simplifiedMasternodeEntry claimedWithOwnerWallet:(DSWallet *)ownerWallet ownerKeyIndex:(uint32_t)ownerKeyIndex {
    NSParameterAssert(simplifiedMasternodeEntry);
    NSParameterAssert(ownerWallet);

    DSLocalMasternode *localMasternode = [self localMasternodeHavingProviderRegistrationTransactionHash:simplifiedMasternodeEntry.providerRegistrationTransactionHash];

    if (localMasternode) return localMasternode;

    uint32_t votingIndex;
    DSWallet *votingWallet = [simplifiedMasternodeEntry.chain walletHavingProviderVotingAuthenticationHash:simplifiedMasternodeEntry.keyIDVoting foundAtIndex:&votingIndex];

    uint32_t operatorIndex;
    DSWallet *operatorWallet = [simplifiedMasternodeEntry.chain walletHavingProviderOperatorAuthenticationKey:simplifiedMasternodeEntry.operatorPublicKey foundAtIndex:&operatorIndex];

    if (votingWallet || operatorWallet) {
        return [[DSLocalMasternode alloc] initWithSocketAddress:simplifiedMasternodeEntry.socketAddress inFundsWallet:nil fundsWalletIndex:0 inOperatorWallet:operatorWallet operatorWalletIndex:operatorIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerKeyIndex inVotingWallet:votingWallet votingWalletIndex:votingIndex];
    } else {
        return nil;
    }
}

- (DSLocalMasternode *)localMasternodeFromProviderRegistrationTransaction:(DSProviderRegistrationTransaction *)providerRegistrationTransaction save:(BOOL)save {
    NSParameterAssert(providerRegistrationTransaction);

    //First check to see if we have a local masternode for this provider registration hash

    @synchronized(self) {
        DSLocalMasternode *localMasternode = self.localMasternodesDictionaryByRegistrationTransactionHash[uint256_data(providerRegistrationTransaction.txHash)];

        if (localMasternode) {
            //We do
            //todo Update keys
            return localMasternode;
        }
        //We don't
        localMasternode = [[DSLocalMasternode alloc] initWithProviderTransactionRegistration:providerRegistrationTransaction];

        if (localMasternode.noLocalWallet) return nil;
        [self.localMasternodesDictionaryByRegistrationTransactionHash setObject:localMasternode forKey:uint256_data(providerRegistrationTransaction.txHash)];
        if (save) {
            [localMasternode save];
        }
        return localMasternode;
    }
}

- (DSLocalMasternode *)localMasternodeHavingProviderRegistrationTransactionHash:(UInt256)providerRegistrationTransactionHash {
    DSLocalMasternode *localMasternode = self.localMasternodesDictionaryByRegistrationTransactionHash[uint256_data(providerRegistrationTransactionHash)];

    return localMasternode;
}

- (DSLocalMasternode *)localMasternodeUsingIndex:(uint32_t)index atDerivationPath:(DSDerivationPath *)derivationPath {
    NSParameterAssert(derivationPath);

    for (DSLocalMasternode *localMasternode in self.localMasternodesDictionaryByRegistrationTransactionHash.allValues) {
        switch (derivationPath.reference) {
            case DSDerivationPathReference_ProviderFunds:
                if (localMasternode.holdingKeysWallet == derivationPath.wallet && localMasternode.holdingWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderOwnerKeys:
                if (localMasternode.ownerKeysWallet == derivationPath.wallet && localMasternode.ownerWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderOperatorKeys:
                if (localMasternode.operatorKeysWallet == derivationPath.wallet && localMasternode.operatorWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderVotingKeys:
                if (localMasternode.votingKeysWallet == derivationPath.wallet && localMasternode.votingWalletIndex == index) {
                    return localMasternode;
                }
                break;
            default:
                break;
        }
    }

    return nil;
}

- (NSArray<DSLocalMasternode *> *)localMasternodesPreviouslyUsingIndex:(uint32_t)index atDerivationPath:(DSDerivationPath *)derivationPath {
    NSParameterAssert(derivationPath);
    if (derivationPath.reference == DSDerivationPathReference_ProviderFunds || derivationPath.reference == DSDerivationPathReference_ProviderOwnerKeys) {
        return nil;
    }

    NSMutableArray *localMasternodes = [NSMutableArray array];

    for (DSLocalMasternode *localMasternode in self.localMasternodesDictionaryByRegistrationTransactionHash.allValues) {
        switch (derivationPath.reference) {
            case DSDerivationPathReference_ProviderOperatorKeys:
                if (localMasternode.operatorKeysWallet == derivationPath.wallet && [localMasternode.previousOperatorWalletIndexes containsIndex:index]) {
                    [localMasternodes addObject:localMasternode];
                }
                break;
            case DSDerivationPathReference_ProviderVotingKeys:
                if (localMasternode.votingKeysWallet == derivationPath.wallet && [localMasternode.previousVotingWalletIndexes containsIndex:index]) {
                    [localMasternodes addObject:localMasternode];
                }
                break;
            default:
                break;
        }
    }
    return [localMasternodes copy];
}

- (NSUInteger)localMasternodesCount {
    return [self.localMasternodesDictionaryByRegistrationTransactionHash count];
}

- (NSArray<DSLocalMasternode *> *)localMasternodes {
    return [self.localMasternodesDictionaryByRegistrationTransactionHash allValues];
}


@end
