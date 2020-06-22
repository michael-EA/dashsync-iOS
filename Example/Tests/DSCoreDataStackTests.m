//  
//  Created by Andrew Podkovyrin
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

#import <DashSync/DashSync.h>

@interface DSCoreDataStackTests : XCTestCase <NSFetchedResultsControllerDelegate>

@property (nonatomic, strong) XCTestExpectation *expectation;

@end

@implementation DSCoreDataStackTests

- (void)testTransactionsPersistance {
    NSManagedObjectContext *context = [NSManagedObjectContext viewContext];

    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:NSStringFromClass(DSTransactionEntity.class) inManagedObjectContext:context];
    
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"lockTime" ascending:YES];
    fetchRequest.sortDescriptors = @[sortDescriptor];

    NSFetchedResultsController *fetchedResultsController =
        [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest
                                            managedObjectContext:context
                                              sectionNameKeyPath:nil
                                                       cacheName:nil];
    fetchedResultsController.delegate = self;

    NSError *error = nil;
    if (![fetchedResultsController performFetch:&error]) {
        // Replace this implementation with code to handle the error appropriately.
        // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
        DSLogError(@"Unresolved error %@, %@", error, [error userInfo]);
        abort();
    }
    
    DSChain *chain = [DSChain mainnet];
    DSTransaction *transaction = [[DSTransaction alloc] initOnChain:chain];
    transaction.txHash = uint256_RANDOM;
    
    XCTestExpectation *expectation = [[XCTestExpectation alloc] init];
    self.expectation = expectation;
    
    [transaction save];
    
    [self waitForExpectations:@[expectation] timeout:10];
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    [self.expectation fulfill];
}

@end
