//
//  DSPeer+Protected.h
//  DashSync
//
//  Created by Sam Westrich on 6/30/19.
//

#import "DSPeer.h"

NS_ASSUME_NONNULL_BEGIN

@interface DSPeer ()

- (instancetype)initWithAddress:(UInt128)address port:(uint16_t)port type:(DSPeerType)peerType onChain:(DSChain*)chain timestamp:(NSTimeInterval)timestamp services:(uint64_t)services;
- (instancetype)initWithHost:(NSString *)host onChain:(DSChain*)chain;

@end

NS_ASSUME_NONNULL_END
