/*
 * LipikaIME is a user-configurable phonetic Input Method Engine for Mac OS X.
 * Copyright (C) 2013 Ranganath Atreya
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 */

#import "DJLipikaBufferManager.h"
#import "DJInputEngineFactory.h"
#import "DJLipikaUserSettings.h"
#import "DJSchemeHelper.h"
#import "DJLogger.h"

@implementation DJLipikaBufferManager

static NSRegularExpression *whiteSpace;

+(void)initialize {
    NSError *error;
    whiteSpace = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:&error];
    if (error != nil) {
        [NSException raise:@"Invalid whitespace regular expression" format:@"Regular expression error: %@", [error localizedDescription]];
    }
}

-(id)init {
    self = [super init];
    if (self == nil) {
        return self;
    }
    engine = [DJInputEngineFactory inputEngine];
    if (engine == nil) {
        return nil;
    }
    [self commonInit];
    return self;
}

// Only for testing purposes and not exposed in the interface
-(id)initWithEngine:(DJInputMethodEngine *)myEngine {
    self = [super init];
    if (self == nil) {
        return self;
    }
    engine = myEngine;
    [self commonInit];
    return self;
}

-(void)commonInit {
    uncommittedOutput = [[NSMutableArray alloc] initWithCapacity:0];
    finalizedIndex = 0;
}

-(void)changeToSchemeWithName:(NSString *)schemeName forScript:(NSString *)scriptName type:(enum DJSchemeType)type {
    [DJLipikaUserSettings setScriptName:scriptName];
    [DJLipikaUserSettings setSchemeName:schemeName];
    [DJLipikaUserSettings setSchemeType:type];
    @synchronized (self) {
        [DJInputEngineFactory setCurrentSchemeWithName:schemeName scriptName:scriptName type:type];
        engine = [DJInputEngineFactory inputEngine];
    }
}

-(NSString *)outputForInput:(NSString *)string previousText:(NSString *)previousText {
    @synchronized(self) {
        // Handle non-character strings
        if (string.length > 1) {
            NSMutableArray *aggregate = [[NSMutableArray alloc] initWithCapacity:0];
            NSArray *characters = charactersForString(string);
            NSString *output = [self outputForInput:characters[0] previousText:previousText];
            if (output) [aggregate addObject:output];
            for (int i = 1; i < [output length]; i++) {
                NSString *output = [self outputForInput:characters[i]];
                if (output) [aggregate addObject:output];
            }
            return aggregate.count ? [aggregate componentsJoinedByString:@""] : nil;
        }
        // Don't use previous text if stop character or whitespace
        BOOL isStopChar = [string isEqualToString:[[engine scheme] stopChar]];
        BOOL isWhiteSpace = [whiteSpace numberOfMatchesInString:string options:0 range:NSMakeRange(0, [string length])];
        if (isStopChar || isWhiteSpace || !previousText) {
            return [self outputForInput:string];
        }
        DJParseOutput *previousResult = [engine.scheme.reverseMappings inputForOutput:previousText];
        NSString *currentResult;
        if (previousResult) {
            replacement = previousResult.output;
            currentResult = [self outputForInput:[previousResult.input stringByAppendingString:string]];
        }
        else {
            currentResult = [self outputForInput:string];
        }
        return currentResult;
    }
}

-(NSString *)outputForInput:(NSString *)string {
    @synchronized(self) {
        if (string.length < 1) return string;
        // Handle non-character strings
        if (string.length > 1) {
            NSMutableArray *aggregate = [[NSMutableArray alloc] initWithCapacity:0];
            for (NSString *singleInput in charactersForString(string)) {
                NSString *output = [self outputForInput:singleInput];
                if (output) [aggregate addObject:output];
            }
            return aggregate.count ? [aggregate componentsJoinedByString:@""] : nil;
        }
        // Fush if stop character or whitespace
        BOOL isStopChar = [string isEqualToString:[[engine scheme] stopChar]];
        BOOL isWhiteSpace = [whiteSpace numberOfMatchesInString:string options:0 range:NSMakeRange(0, [string length])];
        if (isWhiteSpace) {
            [uncommittedOutput addObject:[DJParseOutput sameInputOutput:string]];
            return [self flush];
        }
        if (isStopChar) {
            // Only include the stop character if it does nothing to the engine
            if ([engine isAtRoot]) {
                [uncommittedOutput addObject:[DJParseOutput sameInputOutput:string]];
            }
            else {
                [uncommittedOutput addObject:[DJParseOutput sameInputOutput:[[engine inputsSinceLastOutput] componentsJoinedByString:@""]]];
            }
            finalizedIndex = [uncommittedOutput count];
            [engine reset];
            return nil;
        }
        NSArray *results = [engine executeWithInput:string];
        [self handleResults:results];
        return nil;
    }
}

-(void)handleResults:(NSArray *)results {
    for (DJParseOutput *result in results) {
        if ([result isPreviousFinal]) {
            finalizedIndex = [uncommittedOutput count];
            // Post-process the last two inputs
            if (uncommittedOutput.count > 2) {
                [engine.scheme postProcessResult:[uncommittedOutput lastObject] withPreviousResult:uncommittedOutput[uncommittedOutput.count - 2]];
            }
        }
        else {
            // If there is a replacement then remove unfinalized
            if ([result output] != nil) {
                [self removeUnfinalized];
            }
        }
        if ([result output] != nil) {
            [uncommittedOutput addObject:result];
        }
        if ([result isFinal]) {
            // This includes any additions
            finalizedIndex = [uncommittedOutput count];
        }
    }
}

-(void)removeUnfinalized {
    @synchronized(self) {
        while ([uncommittedOutput count] > finalizedIndex) {
            [uncommittedOutput removeObjectAtIndex:finalizedIndex];
        }
    }
}

-(void)removeLastMapping {
    [uncommittedOutput removeLastObject];
    if (finalizedIndex > [uncommittedOutput count]) {
        finalizedIndex = [uncommittedOutput count];
    }
}

-(BOOL)hasDeletable {
    return [uncommittedOutput count] > 0 || [engine hasDeletable];
}

-(void)delete {
    @synchronized(self) {
        if ([engine hasDeletable]) {
            // First clear out any inputs that have not produced output yet
            [engine reset];
            if ([uncommittedOutput count] > 0) {
                if (finalizedIndex == [uncommittedOutput count]) --finalizedIndex;
                DJParseOutput *lastBundle = [uncommittedOutput lastObject];
                if (lastBundle) [engine executeWithInput:lastBundle.input];
            }
        }
        else if ([uncommittedOutput count] > 0) {
            [engine reset];
            enum DJBackspaceBehavior behavior = [DJLipikaUserSettings backspaceBehavior];
            if (behavior == DJ_DELETE_MAPPING) {
                [self removeLastMapping];
            }
            else if (behavior == DJ_DELETE_INPUT) {
                DJParseOutput *lastBundle = [uncommittedOutput lastObject];
                [self removeLastMapping];
                if (lastBundle.input.length > 1) {
                    NSString *input = [lastBundle.input substringToIndex:lastBundle.input.length - 1];
                    if (input.length > 0) {
                        NSArray *results = [engine executeWithInput:input];
                        [self handleResults:results];
                    }
                }
                else if ([uncommittedOutput count] > 0) {
                    if (finalizedIndex == [uncommittedOutput count]) --finalizedIndex;
                    lastBundle = [uncommittedOutput lastObject];
                    if (lastBundle) [engine executeWithInput:lastBundle.input];
                }
            }
            else {
                logError(@"Unrecognized backspace behavior");
            }
        }
        // If there are no more glyphs then reset the replacement string
        if (![self hasDeletable]) {
            replacement = nil;
        }
    }
}

-(BOOL)hasOutput {
    return [uncommittedOutput count] > 0;
}

-(NSString *)output {
    if ([uncommittedOutput count] <= 0) {
        return nil;
    }
    NSMutableString *word = [[NSMutableString alloc] init];
    for (DJParseOutput *bundle in uncommittedOutput) {
        [word appendString:[bundle output]];
    }
    return word;
}

-(NSString *)input {
    if ([uncommittedOutput count] <= 0) {
        return nil;
    }
    NSMutableString *word = [[NSMutableString alloc] init];
    for (DJParseOutput *bundle in uncommittedOutput) {
        [word appendString:[bundle input]];
    }
    // Add in the inputs that have yet to generate an output
    [word appendString:[[engine inputsSinceLastOutput] componentsJoinedByString:@""]];
    return word;
}

-(int)maxOutputLength {
    return [engine.scheme.reverseMappings maxOutputSize];
}

-(NSString *)replacement {
    return replacement;
}

-(NSString *)flush {
    @synchronized(self) {
        [engine reset];
        NSString *result = [self output];
        [self reset];
        return result;
    }
}

-(NSString *)revert {
    @synchronized(self) {
        NSString *previous = replacement;
        [self flush];
        return previous;
    }
}

-(void)reset {
    @synchronized(self) {
        [uncommittedOutput removeAllObjects];
        replacement = nil;
        finalizedIndex = 0;
    }
}

@end