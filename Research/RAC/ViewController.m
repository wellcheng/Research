//
//  ViewController.m
//  RAC
//
//  Created by charvel on 2018/5/5.
//  Copyright © 2018年 charvel. All rights reserved.
//

#import "ViewController.h"
#import "RSRacBind.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    [self rs_bind];
}

- (void)rs_bind {
    [RSRacBind bind1];
}

@end
