//
//  DSGovernanceObject.m
//  DashSync
//
//  Created by Sam Westrich on 6/11/18.
//

#import "DSGovernanceObject.h"
#import "DSAccount.h"
#import "DSChain+Protected.h"
#import "DSChainEntity+CoreDataProperties.h"
#import "DSChainManager.h"
#import "DSGovernanceObjectEntity+CoreDataProperties.h"
#import "DSGovernanceSyncManager.h"
#import "DSGovernanceVote.h"
#import "DSGovernanceVoteEntity+CoreDataProperties.h"
#import "DSGovernanceVoteHashEntity+CoreDataProperties.h"
#import "DSOptionsManager.h"
#import "DSPeer.h"
#import "DSPeerManager.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "NSData+DSHash.h"
#import "NSData+Dash.h"
#import "NSManagedObject+Sugar.h"
#import "NSMutableData+Dash.h"

#define REQUEST_GOVERNANCE_VOTE_COUNT 500

@interface DSGovernanceObject ()

@property (nonatomic, assign) UInt256 collateralHash;
@property (nonatomic, assign) UInt256 parentHash;
@property (nonatomic, assign) uint32_t revision;
@property (nonatomic, strong) NSData *signature;
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, assign) DSGovernanceObjectType type;
@property (nonatomic, assign) UInt256 governanceObjectHash;
@property (nonatomic, strong) DSChain *chain;
@property (nullable, nonatomic, strong) NSString *identifier;
@property (nonatomic, assign) uint64_t amount;
@property (nonatomic, assign) uint64_t startEpoch;
@property (nonatomic, assign) uint64_t endEpoch;
@property (nullable, nonatomic, strong) NSString *paymentAddress;
@property (nullable, nonatomic, strong) NSString *url;
@property (nonatomic, assign) BOOL finishedSync;

@property (nonatomic, strong) NSOrderedSet *knownGovernanceVoteHashes;
@property (nonatomic, strong) NSMutableOrderedSet<NSData *> *knownGovernanceVoteHashesForExistingGovernanceVotes;
@property (nonatomic, readonly) NSOrderedSet *fulfilledRequestsGovernanceVoteHashEntities;
@property (nonatomic, strong) NSMutableArray *needsRequestsGovernanceVoteHashEntities;
@property (nonatomic, strong) NSMutableArray *requestGovernanceVoteHashEntities;
@property (nonatomic, strong) NSMutableArray<DSGovernanceVote *> *governanceVotes;
@property (nonatomic, assign) NSUInteger governanceVotesCount;

@end

@implementation DSGovernanceObject

//From the reference implementation
//
//uint256 CGovernanceObject::GetHash() const
//{
//    // Note: doesn't match serialization
//
//    // CREATE HASH OF ALL IMPORTANT PIECES OF DATA
//
//    CHashWriter ss(SER_GETHASH, PROTOCOL_VERSION);
//    ss << nHashParent;
//    ss << nRevision;
//    ss << nTime;
//    ss << GetDataAsHexString();
//    ss << masternodeOutpoint << uint8_t{} << 0xffffffff; // adding dummy values here to match old hashing
//    ss << vchSig;
//    // fee_tx is left out on purpose
//
//    DBG( printf("CGovernanceObject::GetHash %i %li %s\n", nRevision, nTime, GetDataAsHexString().c_str()); );
//
//    return ss.GetHash();
//}

+ (UInt256)hashWithParentHash:(NSData *)parentHashData revision:(uint32_t)revision timeStampData:(NSData *)timestampData governanceMessageHexData:(NSData *)hexData masternodeUTXO:(DSUTXO)masternodeUTXO signature:(NSData *)signature onChain:(DSChain *)chain {
    //hash calculation
    NSMutableData *hashImportantData = [NSMutableData data];
    [hashImportantData appendData:parentHashData];
    [hashImportantData appendBytes:&revision length:4];
    [hashImportantData appendData:timestampData];

    [hashImportantData appendData:hexData];

    uint32_t index = (uint32_t)masternodeUTXO.n;
    [hashImportantData appendData:[NSData dataWithUInt256:masternodeUTXO.hash]];
    [hashImportantData appendBytes:&index length:4];
    uint8_t emptyByte = 0;
    uint32_t fullBits = UINT32_MAX;
    [hashImportantData appendBytes:&emptyByte length:1];
    [hashImportantData appendBytes:&fullBits length:4];
    uint8_t signatureSize = [signature length];
    [hashImportantData appendBytes:&signatureSize length:1];
    [hashImportantData appendData:signature];
    return hashImportantData.SHA256_2;
}

+ (DSGovernanceObject *_Nullable)governanceObjectFromMessage:(NSData *)message onChain:(DSChain *)chain {
    NSParameterAssert(message);
    NSParameterAssert(chain);

    NSUInteger length = message.length;
    NSUInteger offset = 0;
    if (length - offset < 32) return nil;
    NSData *parentHashData = [message subdataWithRange:NSMakeRange(offset, 32)];
    UInt256 parentHash = [message UInt256AtOffset:offset];
    offset += 32;
    if (length - offset < 4) return nil;
    uint32_t revision = [message UInt32AtOffset:offset];
    offset += 4;
    if (length - offset < 8) return nil;
    NSData *timestampData = [message subdataWithRange:NSMakeRange(offset, 8)];
    uint64_t timestamp = [message UInt64AtOffset:offset];
    offset += 8;
    if (length - offset < 32) return nil;
    UInt256 collateralHash = [message UInt256AtOffset:offset];
    offset += 32;
    NSNumber *varIntLength = nil;
    NSData *governanceMessageData;
    NSData *hexData;
    if (chain.protocolVersion < 70209) { //switch to outpoint in 70209
        governanceMessageData = [NSData dataFromHexString:[message stringAtOffset:offset length:&varIntLength]];
        hexData = [message subdataWithRange:NSMakeRange(offset, varIntLength.integerValue)];
    } else {
        NSMutableData *mHexData = [NSMutableData data];
        governanceMessageData = [[message stringAtOffset:offset length:&varIntLength] dataUsingEncoding:NSUTF8StringEncoding];
        [mHexData appendString:[governanceMessageData hexString]];
        hexData = [mHexData copy];
    }

    offset += [varIntLength integerValue];
    DSGovernanceObjectType governanceObjectType = [message UInt32AtOffset:offset];
    offset += 4;

    DSUTXO masternodeUTXO;
    if (length - offset < 32) return nil;
    masternodeUTXO.hash = [message UInt256AtOffset:offset];
    offset += 32;
    if (length - offset < 4) return nil;
    masternodeUTXO.n = [message UInt32AtOffset:offset];
    offset += 4;
    if (chain.protocolVersion < 70209) { //switch to outpoint in 70209
        if (length - offset < 1) return nil;
        uint8_t sigscriptSize = [message UInt8AtOffset:offset];
        offset += 1;
        if (length - offset < sigscriptSize) return nil;
        //NSData * sigscript = [message subdataWithRange:NSMakeRange(offset, sigscriptSize)];
        offset += sigscriptSize;
        if (length - offset < 4) return nil;
        //uint32_t sequenceNumber = [message UInt32AtOffset:offset];
        offset += 4;
    }

    if (length - offset < 1) return nil;
    uint8_t messageSignatureSize = [message UInt8AtOffset:offset];
    offset += 1;
    if (length - offset < messageSignatureSize) return nil;
    NSData *messageSignature = [message subdataWithRange:NSMakeRange(offset, messageSignatureSize)];
    offset += messageSignatureSize;

    NSString *identifier = nil;
    uint64_t amount = 0;
    uint64_t startEpoch = 0;
    uint64_t endEpoch = 0;
    NSString *paymentAddress = nil;
    NSString *url = nil;

    if (governanceObjectType == DSGovernanceObjectType_Proposal) {
        NSError *jsonError = nil;


        id governanceArray = [NSJSONSerialization JSONObjectWithData:governanceMessageData options:0 error:&jsonError];
        NSDictionary *proposalDictionary = [governanceArray isKindOfClass:[NSDictionary class]] ? governanceArray : nil;
        while (!proposalDictionary) {
            if ([governanceArray count]) {
                if ([governanceArray count] > 1 && [[governanceArray objectAtIndex:0] isEqualToString:@"proposal"]) {
                    proposalDictionary = [governanceArray objectAtIndex:1];
                } else if ([[governanceArray objectAtIndex:0] isKindOfClass:[NSArray class]]) {
                    governanceArray = [governanceArray objectAtIndex:0];
                } else if ([[governanceArray objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
                    proposalDictionary = [governanceArray objectAtIndex:0];
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (proposalDictionary) {
            identifier = proposalDictionary[@"name"];
            startEpoch = [proposalDictionary[@"start_epoch"] longLongValue];
            endEpoch = [proposalDictionary[@"end_epoch"] longLongValue];
            paymentAddress = proposalDictionary[@"payment_address"];
            amount = [[[NSDecimalNumber decimalNumberWithDecimal:[proposalDictionary[@"payment_amount"] decimalValue]] decimalNumberByMultiplyingByPowerOf10:8] unsignedLongLongValue];
            url = proposalDictionary[@"url"];
        }
    }

    UInt256 governanceObjectHash = [self hashWithParentHash:parentHashData revision:revision timeStampData:timestampData governanceMessageHexData:hexData masternodeUTXO:masternodeUTXO signature:messageSignature onChain:chain];

    DSGovernanceObject *governanceObject = [[DSGovernanceObject alloc] initWithType:governanceObjectType parentHash:parentHash revision:revision timestamp:timestamp signature:messageSignature collateralHash:collateralHash governanceObjectHash:governanceObjectHash identifier:identifier amount:amount startEpoch:startEpoch endEpoch:endEpoch paymentAddress:paymentAddress url:url onChain:chain];
    return governanceObject;
}

- (UInt256)governanceObjectHash {
    if (uint256_eq(_governanceObjectHash, UINT256_ZERO)) {
        NSTimeInterval timestamp = self.timestamp;
        DSUTXO o;
        o.hash = UINT256_ZERO;
        o.n = 0;
        _governanceObjectHash = [DSGovernanceObject hashWithParentHash:[NSData dataWithUInt256:self.parentHash] revision:self.revision timeStampData:[NSData dataWithBytes:&timestamp length:sizeof(timestamp)] governanceMessageHexData:self.proposalInfo masternodeUTXO:o signature:[NSData data] onChain:self.chain];
    }
    return _governanceObjectHash;
}

- (NSData *)dataMessage {
    NSMutableData *data = [NSMutableData data];
    [data appendUInt256:self.parentHash];
    [data appendUInt32:self.revision];
    [data appendUInt64:self.timestamp];
    [data appendUInt256:self.collateralHash];
    [data appendString:[[NSString alloc] initWithData:[self proposalInfo] encoding:NSUTF8StringEncoding]];
    [data appendUInt32:self.type];
    [data appendUInt256:UINT256_ZERO];
    [data appendUInt32:0];
    [data appendUInt8:0];
    return [data copy];
}

- (instancetype)initWithType:(DSGovernanceObjectType)governanceObjectType parentHash:(UInt256)parentHash revision:(uint32_t)revision timestamp:(NSTimeInterval)timestamp signature:(NSData *)signature collateralHash:(UInt256)collateralHash governanceObjectHash:(UInt256)governanceObjectHash identifier:(NSString *)identifier amount:(uint64_t)amount startEpoch:(uint64_t)startEpoch endEpoch:(uint64_t)endEpoch paymentAddress:(NSString *)paymentAddress url:(NSString *)url onChain:(DSChain *)chain {
    NSParameterAssert(chain);

    if (!(self = [super init])) return nil;

    _signature = signature;
    _revision = revision;
    _timestamp = timestamp;
    _collateralHash = collateralHash;
    _parentHash = parentHash;
    _type = governanceObjectType;
    _chain = chain;
    _governanceObjectHash = governanceObjectHash;
    _identifier = identifier;
    _amount = amount;
    _startEpoch = startEpoch;
    _endEpoch = endEpoch;
    _paymentAddress = paymentAddress;
    _url = url;

    _governanceVotes = [NSMutableArray array];
    if (uint256_is_not_zero(governanceObjectHash)) [self loadGovernanceVotes:0];
    self.managedObjectContext = [NSManagedObjectContext chainContext];

    return self;
}

- (DSGovernanceObjectEntity *)governanceObjectEntityInContext:(NSManagedObjectContext *)context {
    NSArray *governanceObjects = [DSGovernanceObjectEntity objectsInContext:context matching:@"governanceObjectHash.governanceObjectHash = %@", [NSData dataWithUInt256:self.governanceObjectHash]];
    if ([governanceObjects count]) {
        return governanceObjects[0];
    } else {
        DSGovernanceObjectEntity *governanceObjectEntity = [DSGovernanceObjectEntity managedObjectInBlockedContext:context];
        [governanceObjectEntity setAttributesFromGovernanceObject:self forHashEntity:nil];
        return governanceObjectEntity;
    }
}

// MARK:- Governance Vote

- (NSUInteger)recentGovernanceVoteHashesCount {
    __block NSUInteger count = 0;
    [self.managedObjectContext performBlockAndWait:^{
        count = [DSGovernanceVoteHashEntity countAroundNowOnChainEntity:[self.chain chainEntityInContext:self.managedObjectContext]];
    }];
    return count;
}

- (NSUInteger)last3HoursStandaloneGovernanceVoteHashesCount {
    __block NSUInteger count = 0;
    [self.managedObjectContext performBlockAndWait:^{
        count = [DSGovernanceVoteHashEntity standaloneCountInLast3hoursOnChainEntity:[self.chain chainEntityInContext:self.managedObjectContext]];
    }];
    return count;
}

- (NSUInteger)governanceVotesCount {
    __block NSUInteger count = 0;
    [self.managedObjectContext performBlockAndWait:^{
        count = [DSGovernanceVoteEntity countForGovernanceObjectEntity:self.governanceObjectEntity];
    }];
    return count;
}


- (void)loadGovernanceVotes:(NSUInteger)count {
    NSFetchRequest *fetchRequest = [[DSGovernanceVoteEntity fetchRequest] copy];
    if (count) {
        [fetchRequest setFetchLimit:count];
    }
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"governanceVoteHash.governanceObject == %@", self.governanceObjectEntity]];
    [fetchRequest setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"masternode" ascending:TRUE]]];
    NSArray *governanceVoteEntities = [DSGovernanceVoteEntity fetchObjects:fetchRequest inContext:self.managedObjectContext];
    if (!_knownGovernanceVoteHashesForExistingGovernanceVotes) _knownGovernanceVoteHashesForExistingGovernanceVotes = [NSMutableOrderedSet orderedSet];
    for (DSGovernanceVoteEntity *governanceVoteEntity in governanceVoteEntities) {
        DSGovernanceVote *governanceVote = [governanceVoteEntity governanceVote];
        DSLog(@"%@ : %@ -> %d/%d", self.identifier, [NSData dataWithUInt256:governanceVote.masternode.simplifiedMasternodeEntryHash].shortHexString, governanceVote.outcome, governanceVote.signal);
        [_knownGovernanceVoteHashesForExistingGovernanceVotes addObject:[NSData dataWithUInt256:governanceVote.governanceVoteHash]];
        [_governanceVotes addObject:governanceVote];
    }
}

- (NSOrderedSet *)knownGovernanceVoteHashes {
    if (_knownGovernanceVoteHashes) return _knownGovernanceVoteHashes;

    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *request = DSGovernanceVoteHashEntity.fetchReq;
        [request setPredicate:[NSPredicate predicateWithFormat:@"governanceVoteHash.governanceObject = %@", self.governanceObjectEntity]];
        [request setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"governanceVoteHash" ascending:TRUE]]];
        NSArray<DSGovernanceVoteHashEntity *> *knownGovernanceVoteHashEntities = [DSGovernanceVoteHashEntity fetchObjects:request inContext:self.managedObjectContext];
        NSMutableOrderedSet<NSData *> *rHashes = [NSMutableOrderedSet orderedSetWithCapacity:knownGovernanceVoteHashEntities.count];
        for (DSGovernanceVoteHashEntity *knownGovernanceVoteHashEntity in knownGovernanceVoteHashEntities) {
            NSData *hash = knownGovernanceVoteHashEntity.governanceVoteHash;
            [rHashes addObject:hash];
        }
        self.knownGovernanceVoteHashes = [rHashes copy];
    }];
    return _knownGovernanceVoteHashes;
}

- (NSMutableArray *)needsRequestsGovernanceVoteHashEntities {
    if (_needsRequestsGovernanceVoteHashEntities) return _needsRequestsGovernanceVoteHashEntities;

    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *request = DSGovernanceVoteHashEntity.fetchReq;
        [request setPredicate:[NSPredicate predicateWithFormat:@"governanceObject = %@ && governanceVote == nil", self.governanceObjectEntity]];
        [request setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"governanceVoteHash" ascending:TRUE]]];
        self.needsRequestsGovernanceVoteHashEntities = [[DSGovernanceVoteHashEntity fetchObjects:request inContext:self.managedObjectContext] mutableCopy];
    }];
    return _needsRequestsGovernanceVoteHashEntities;
}

- (NSArray *)needsGovernanceVoteRequestsHashes {
    __block NSMutableArray *mArray = [NSMutableArray array];
    [self.managedObjectContext performBlockAndWait:^{
        for (DSGovernanceVoteHashEntity *governanceVoteHashEntity in self.needsRequestsGovernanceVoteHashEntities) {
            [mArray addObject:governanceVoteHashEntity.governanceVoteHash];
        }
    }];
    return [mArray copy];
}

- (NSOrderedSet *)fulfilledRequestsGovernanceVoteHashEntities {
    __block NSOrderedSet *orderedSet;
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *request = DSGovernanceVoteHashEntity.fetchReq;
        [request setPredicate:[NSPredicate predicateWithFormat:@"governanceVoteHash.governanceObject = %@ && governanceVote != nil", self.governanceObjectEntity]];
        [request setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"governanceVoteHash" ascending:TRUE]]];
        orderedSet = [NSOrderedSet orderedSetWithArray:[DSGovernanceVoteHashEntity fetchObjects:request inContext:self.managedObjectContext]];
    }];
    return orderedSet;
}

- (NSOrderedSet *)fulfilledGovernanceVoteRequestsHashes {
    NSMutableOrderedSet *mOrderedSet = [NSMutableOrderedSet orderedSet];
    for (DSGovernanceVoteHashEntity *governanceVoteHashEntity in self.fulfilledRequestsGovernanceVoteHashEntities) {
        [mOrderedSet addObject:governanceVoteHashEntity.governanceVoteHash];
    }
    return [mOrderedSet copy];
}

- (void)requestGovernanceVotesFromPeer:(DSPeer *)peer {
    if (![self.needsRequestsGovernanceVoteHashEntities count]) {
        self.finishedSync = TRUE;
        //we are done syncing
        return;
    }
    self.finishedSync = FALSE;
    self.requestGovernanceVoteHashEntities = [[self.needsRequestsGovernanceVoteHashEntities subarrayWithRange:NSMakeRange(0, MIN(self.needsGovernanceVoteRequestsHashes.count, REQUEST_GOVERNANCE_VOTE_COUNT))] mutableCopy];
    NSMutableArray *requestHashes = [NSMutableArray array];
    for (DSGovernanceVoteHashEntity *governanceVoteHashEntity in self.requestGovernanceVoteHashEntities) {
        [requestHashes addObject:governanceVoteHashEntity.governanceVoteHash];
    }
    peer.governanceRequestState = DSGovernanceRequestState_GovernanceObjectVotes;
    [peer sendGetdataMessageWithGovernanceVoteHashes:requestHashes];
}

- (void)peer:(DSPeer *)peer hasGovernanceVoteHashes:(NSSet *)governanceVoteHashes {
    NSParameterAssert(governanceVoteHashes);

    @synchronized(self) {
        if (!(([[DSOptionsManager sharedInstance] syncType] & DSSyncType_GovernanceVotes) == DSSyncType_GovernanceVotes)) return;
        DSLog(@"peer relayed governance vote hashes");
        if (!self.totalGovernanceVoteCount) {
            [self.delegate governanceObject:self didReceiveUnknownHashes:governanceVoteHashes fromPeer:peer];
        }
        NSMutableOrderedSet *hashesToInsert = [[NSOrderedSet orderedSetWithSet:governanceVoteHashes] mutableCopy];
        NSMutableOrderedSet *hashesToUpdate = [[NSOrderedSet orderedSetWithSet:governanceVoteHashes] mutableCopy];
        NSMutableOrderedSet *hashesToQuery = [[NSOrderedSet orderedSetWithSet:governanceVoteHashes] mutableCopy];
        NSMutableOrderedSet<NSData *> *rHashes = [self.knownGovernanceVoteHashes mutableCopy];
        [hashesToInsert minusOrderedSet:self.knownGovernanceVoteHashes];
        [hashesToUpdate minusOrderedSet:hashesToInsert];
        [hashesToQuery minusOrderedSet:self.fulfilledGovernanceVoteRequestsHashes];
        NSMutableOrderedSet *hashesToQueryFromInsert = [hashesToQuery mutableCopy];
        [hashesToQueryFromInsert intersectOrderedSet:hashesToInsert];
        NSMutableArray *hashEntitiesToQuery = [NSMutableArray array];
        if ([governanceVoteHashes count]) {
            [self.managedObjectContext performBlockAndWait:^{
                DSGovernanceObjectEntity *governanceObjectEntity = self.governanceObjectEntity;
                if ([hashesToInsert count]) {
                    NSArray *novelGovernanceVoteHashEntities = [DSGovernanceVoteHashEntity governanceVoteHashEntitiesWithHashes:hashesToInsert forGovernanceObjectEntity:governanceObjectEntity];
                    for (DSGovernanceVoteHashEntity *governanceVoteHashEntity in novelGovernanceVoteHashEntities) {
                        if ([hashesToQueryFromInsert containsObject:governanceVoteHashEntity.governanceVoteHash]) {
                            [hashEntitiesToQuery addObject:governanceVoteHashEntity];
                        }
                    }
                }
                if ([hashesToUpdate count]) {
                    [DSGovernanceVoteHashEntity updateTimestampForGovernanceVoteHashEntitiesWithGovernanceVoteHashes:hashesToUpdate forGovernanceObjectEntity:governanceObjectEntity];
                }
                [self.managedObjectContext ds_save];
            }];
            if ([hashesToInsert count]) {
                [rHashes addObjectsFromArray:[hashesToInsert array]];
                [rHashes sortUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
                    UInt256 a = *(UInt256 *)((NSData *)obj1).bytes;
                    UInt256 b = *(UInt256 *)((NSData *)obj2).bytes;
                    return uint256_sup(a, b) ? NSOrderedAscending : NSOrderedDescending;
                }];
            }
        }
        self.knownGovernanceVoteHashes = rHashes;
        self.needsRequestsGovernanceVoteHashEntities = nil; //just so it can lazy load again
        DSLog(@"-> %lu - %lu", (unsigned long)[self.knownGovernanceVoteHashes count], (unsigned long)self.totalGovernanceVoteCount);
        if ([self.knownGovernanceVoteHashes count] >= self.totalGovernanceVoteCount) {
            //we have more than we should have
            //for a vote it doesn't matter and will happen often
            DSLog(@"All governance vote hashes received for object %@", self.identifier);
            //        [self.managedObjectContext performBlockAndWait:^{
            //            [DSGovernanceVoteHashEntity setContext:self.managedObjectContext];
            //            [DSGovernanceVoteHashEntity removeOldest:countAroundNow - self.totalGovernanceVoteCount hashesNotIn:governanceVoteHashes onChain:[self.chain chainEntityInContext:context]];
            //            [DSGovernanceVoteHashEntity saveContext];
            //        }];
            [self requestGovernanceVotesFromPeer:peer];
        } // else {
          //things are missing, most likely they will come in later
        //}
    }
}

- (void)peer:(DSPeer *)peer relayedGovernanceVote:(DSGovernanceVote *)governanceVote {
    NSParameterAssert(governanceVote);

    NSData *governanceVoteHash = [NSData dataWithUInt256:governanceVote.governanceVoteHash];
    DSGovernanceVoteHashEntity *relatedHashEntity = nil;
    for (DSGovernanceVoteHashEntity *governanceVoteHashEntity in [self.requestGovernanceVoteHashEntities copy]) {
        if ([governanceVoteHashEntity.governanceVoteHash isEqual:governanceVoteHash]) {
            relatedHashEntity = governanceVoteHashEntity;
            [self.requestGovernanceVoteHashEntities removeObject:governanceVoteHashEntity];
            break;
        }
    }
    //NSAssert(relatedHashEntity, @"There needs to be a relatedHashEntity");
    if (!relatedHashEntity) return;
    //todo this seems weird
    [[DSGovernanceVoteEntity managedObjectInBlockedContext:self.managedObjectContext] setAttributesFromGovernanceVote:governanceVote forHashEntity:relatedHashEntity];
    [self.needsRequestsGovernanceVoteHashEntities removeObject:relatedHashEntity];
    [self.governanceVotes addObject:governanceVote];
    if (![self.requestGovernanceVoteHashEntities count]) {
        [self requestGovernanceVotesFromPeer:peer];
        [self.managedObjectContext ds_save];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DSGovernanceVotesDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey: peer.chain}];
        });
    }
}

- (void)save {
    [self.managedObjectContext performBlockAndWait:^{
        DSGovernanceObjectEntity *governanceObjectEntity = self.governanceObjectEntity;
        governanceObjectEntity.totalVotesCount = self.totalGovernanceVoteCount;
        [self.managedObjectContext ds_save];
    }];
}

- (NSData *)proposalInfo {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    dictionary[@"name"] = self.identifier;
    dictionary[@"start_epoch"] = @(self.startEpoch);
    dictionary[@"end_epoch"] = @(self.endEpoch);
    dictionary[@"type"] = @(1);
    dictionary[@"payment_address"] = self.paymentAddress;
    dictionary[@"payment_amount"] = [NSDecimalNumber decimalNumberWithMantissa:self.amount exponent:-8 isNegative:FALSE];
    dictionary[@"url"] = self.url;
    NSArray *proposalArray = @[@[@"proposal", dictionary]];
    NSError *error = nil;
    if (@available(iOS 11.0, *)) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:proposalArray options:NSJSONWritingSortedKeys error:&error];
        NSString *dataString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dataString = [dataString stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
        data = [dataString dataUsingEncoding:NSUTF8StringEncoding];
        return data;
    } else {
        //figure out how to handle this on iOS 10
        NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
        return data;
        // Fallback on earlier versions
    }
}


- (DSTransaction *)collateralTransactionForAccount:(DSAccount *)account {
    NSParameterAssert(account);
    DSTransaction *collateralTransaction = [account proposalCollateralTransactionWithData:[self proposalInfo]];
    return collateralTransaction;
}

- (void)registerCollateralTransaction:(DSTransaction *)transaction {
    NSParameterAssert(transaction);

    self.collateralHash = transaction.txHash;
}

- (BOOL)isValid {
    if (self.type == DSGovernanceObjectType_Proposal) {
        if (!self.startEpoch) return FALSE;
        if (!self.endEpoch) return FALSE;
        if (!self.identifier) return FALSE;
        if (!self.paymentAddress) return FALSE;
        if (!self.amount) return FALSE;
        if (!self.url) return FALSE;
        if (uint256_is_not_zero(self.parentHash)) return FALSE;
        if (uint256_is_zero(self.collateralHash)) return FALSE;

    } else if (self.type == DSGovernanceObjectType_Trigger) {
        //todo validation here
        return TRUE;
    }
    return FALSE;
}

@end
