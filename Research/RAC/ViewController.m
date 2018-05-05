//
//  ViewController.m
//  RAC
//
//  Created by charvel on 2018/5/5.
//  Copyright © 2018年 charvel. All rights reserved.
//

#import "ViewController.h"
#import "RSRacBind.h"
#import "RSRacConcat.h"

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
    [RSRacBind bind1];
}

- (void)rs_concat {
    [RSRacConcat concat];
}

@end
