//
//  ViewController.m
//  RAC
//
//  Created by charvel on 2018/5/5.
//  Copyright © 2018年 charvel. All rights reserved.
//

#import "ViewController.h"
#import "RSRacOperations.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
}

- (IBAction)doOperator:(UIButton *)sender {
    NSString *method = [NSString stringWithFormat:@"rs_%@", sender.titleLabel.text.lowercaseString];
    SEL selector = NSSelectorFromString(method);
    [self performSelector:selector];
}

- (void)rs_bind {
    [RSRacOperations bind];
}

- (void)rs_concat {
    [RSRacOperations concat];
}

- (void)rs_operation {
    NSString *method = @"repeat";
    
    SEL selector = NSSelectorFromString(method);
    [RSRacOperations performSelector:selector];
}

@end
