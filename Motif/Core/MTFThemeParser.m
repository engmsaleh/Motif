//
//  MTFThemeParser.m
//  Motif
//
//  Created by Eric Horacek on 2/11/15.
//  Copyright (c) 2015 Eric Horacek. All rights reserved.
//

#import "MTFThemeParser.h"
#import "MTFThemeConstant.h"
#import "MTFThemeConstant_Private.h"
#import "MTFThemeClass.h"
#import "MTFThemeClass_Private.h"
#import "MTFTheme.h"
#import "MTFThemeSymbolReference.h"
#import "MTFTheme_Private.h"
#import "NSString+ThemeSymbols.h"
#import "NSDictionary+IntersectingKeys.h"
#import "NSDictionary+DictionaryValueValidation.h"

@implementation MTFThemeParser

#pragma mark - Public

- (instancetype)initWithRawTheme:(NSDictionary *)rawTheme inheritingFromTheme:(MTFTheme *)theme error:(NSError *__autoreleasing *)error {
    NSParameterAssert(rawTheme);
    
    self = [super init];
    if (self) {
        _rawTheme = rawTheme;
        
        // Filter out the constants and classes from the raw dictionary
        NSDictionary *rawConstants = [self rawConstantsFromRawTheme:rawTheme];
        NSDictionary *rawClasses = [self rawClassesFromRawTheme:rawTheme];
        
        // Determine the invalid keys from the raw theme
        NSArray *invalidSymbols = [self
            invalidSymbolsFromRawTheme:rawTheme
            rawConstants:rawConstants
            rawClasses:rawClasses];
        if (invalidSymbols.count && error) {
            NSString *localizedDescription = [NSString stringWithFormat:
                @"The following symbols in the theme are invalid %@",
                invalidSymbols];
            *error = [NSError
                errorWithDomain:MTFThemingErrorDomain
                code:0
                userInfo:@{
                    NSLocalizedDescriptionKey: localizedDescription
                }];
        }
        
        // Map the constants from the raw theme
        NSDictionary *parsedConstants = [self
            constantsParsedFromRawConstants:rawConstants
            error:error];
        NSDictionary *parsedClasses = [self
            classesParsedFromRawClasses:rawClasses
            error:error];
        
        if (self.class.shouldResolveReferences) {
            NSDictionary *mergedConstants = [self
                mergeParsedConstants:parsedConstants
                intoExistingConstants:theme.constants
                error:error];
            NSDictionary *mergedClasses = [self
                mergeParsedClasses:parsedClasses
                intoExistingClasses:theme.classes
                error:error];
            
            parsedConstants = [self
                resolveReferenceInParsedConstants:parsedConstants
                fromConstants:mergedConstants
                classes:mergedClasses
                error:error];
            
            parsedClasses = [self
                resolveReferencesInParsedClasses:parsedClasses
                fromConstants:mergedConstants
                classes:mergedClasses
                error:error];
        }
        
        _parsedConstants = parsedConstants;
        _parsedClasses = parsedClasses;
    }
    return self;
}

#pragma mark - Private

#pragma mark Raw Theme Parsing

- (NSDictionary *)rawConstantsFromRawTheme:(NSDictionary *)rawTheme {
    NSMutableDictionary *rawConstants = [NSMutableDictionary new];
    for (NSString *symbol in rawTheme) {
        if (symbol.mtf_isRawSymbolConstantReference) {
            rawConstants[symbol] = rawTheme[symbol];
        }
    }
    return [rawConstants copy];
}

- (NSDictionary *)rawClassesFromRawTheme:(NSDictionary *)rawTheme {
    NSMutableDictionary *rawClasses = [NSMutableDictionary new];
    for (NSString *symbol in rawTheme) {
        if (symbol.mtf_isRawSymbolClassReference) {
            rawClasses[symbol] = rawTheme[symbol];
        }
    }
    return [rawClasses copy];
}

- (NSArray *)invalidSymbolsFromRawTheme:(NSDictionary *)rawThemeDictionary rawConstants:(NSDictionary *)rawConstants rawClasses:(NSDictionary *)rawClasses {
    NSMutableSet *remainingKeys = [NSMutableSet
        setWithArray:rawThemeDictionary.allKeys];
    [remainingKeys minusSet:[NSSet setWithArray:rawConstants.allKeys]];
    [remainingKeys minusSet:[NSSet setWithArray:rawClasses.allKeys]];
    return remainingKeys.allObjects;
}

#pragma mark Constants

- (NSDictionary *)constantsParsedFromRawConstants:(NSDictionary *)rawConstants error:(NSError *__autoreleasing *)error {
    NSMutableDictionary *parsedConstants = [NSMutableDictionary new];
    for (NSString *rawSymbol in rawConstants) {
        id rawValue = rawConstants[rawSymbol];
        MTFThemeConstant *constant = [self
            constantParsedFromRawSymbol:rawSymbol
            rawValue:rawValue
            error:error];
        parsedConstants[constant.name] = constant;
    };
    return [parsedConstants copy];
}

- (MTFThemeConstant *)constantParsedFromRawSymbol:(NSString *)rawSymbol rawValue:(id)rawValue error:(NSError *__autoreleasing *)error {
    // If the symbol is a reference (in the case of a root-level constant), use
    // it. Otherwise it is a reference to in a class' properties, so just keep
    // it as-is
    NSString *symbol = rawSymbol;
    if (symbol.mtf_isRawSymbolConstantReference) {
        symbol = rawSymbol.mtf_symbol;
    }
    
    // If the rawValue is not a string, it is not a reference, so return as-is
    if (![rawValue isKindOfClass:NSString.class]) {
        return [[MTFThemeConstant alloc]
            initWithName:symbol
            rawValue:rawValue
            mappedValue:nil];
    }
    
    // We now know that this constant's value is a string, so cast it
    NSString *rawValueString = (NSString *)rawValue;
    MTFThemeSymbolReference *reference;
    
    // Determine if this string value is a symbol reference
    if (rawValueString.mtf_isRawSymbolReference) {
        reference = [[MTFThemeSymbolReference alloc]
            initWithRawSymbol:rawValueString];
    }
    
    return [[MTFThemeConstant alloc]
        initWithName:symbol
        rawValue:rawValue
        mappedValue:reference];
}

- (NSDictionary *)resolveReferencesInParsedClasses:(NSDictionary *)parsedClasses fromConstants:(NSDictionary *)constants classes:(NSDictionary *)classes error:(NSError *__autoreleasing *)error {
    NSMutableDictionary *resolvedClasses = [parsedClasses mutableCopy];
    NSArray *parsedClassObjects = [parsedClasses objectEnumerator].allObjects;
    for (MTFThemeClass *parsedClass in parsedClassObjects) {
        
        // Resolve the references within this class
        parsedClass.propertiesConstants = [self
            resolveReferenceInParsedConstants:parsedClass.propertiesConstants
            fromConstants:constants
            classes:classes
            error:error];
        
        // If there is a superclass reference and it is to invalid property
        id superclass = [parsedClass.propertiesConstants[MTFThemeSuperclassKey]
            mappedValue];
        if (superclass && ![superclass isKindOfClass:MTFThemeClass.class]) {
            // Do not resolve this class
            [resolvedClasses removeObjectForKey:parsedClass.name];
            // Populate the error
            if (error) {
                NSString *localizedDescription = [NSString stringWithFormat:
                    @"The value for the 'superclass' property in '%@' must "
                        "reference a valid theme class. It is currently '%@'",
                    parsedClass.name,
                    superclass];
                *error = [NSError
                    errorWithDomain:MTFThemingErrorDomain
                    code:1
                    userInfo:@{
                        NSLocalizedDescriptionKey: localizedDescription
                    }];
            }
        }
    }
    
    return [resolvedClasses copy];
}

- (NSDictionary *)resolveReferenceInParsedConstants:(NSDictionary *)parsedConstants fromConstants:(NSDictionary *)constants classes:(NSDictionary *)classes error:(NSError *__autoreleasing *)error {
    NSMutableDictionary *resolvedConstants = [parsedConstants mutableCopy];
    
    NSArray *parsedConstantObjects = [parsedConstants
        objectEnumerator].allObjects;
    for (MTFThemeConstant *parsedConstant in parsedConstantObjects) {
        
        id mappedValue = parsedConstant.mappedValue;
        
        // If the constant does not have a reference as its value, continue
        BOOL isMappedValueSymbolReference = [mappedValue
            isKindOfClass:MTFThemeSymbolReference.class];
        if (!mappedValue || !isMappedValueSymbolReference) {
            continue;
        }
        
        // Otherwise, the constant has a symbol reference as its mapped value,
        // so resolve it
        MTFThemeSymbolReference *reference;
        reference = (MTFThemeSymbolReference *)mappedValue;
        
        switch (reference.type) {
        case MTFThemeSymbolTypeConstant: {
            // Locate the referenced constant in the existing constants
            // dictionary
            MTFThemeConstant *constantReference = constants[reference.symbol];
            if (constantReference) {
                parsedConstant.mappedValue = constantReference;
                continue;
            }
            // This is an invalid reference, so remove it from the resolved
            // constants
            [resolvedConstants removeObjectForKey:parsedConstant.name];
            if (error) {
                NSString *localizedDescription = [NSString stringWithFormat:
                    @"The named constant value for property '%@' ('%@') was "
                        "not found as a registered constant",
                    parsedConstant.name,
                    parsedConstant.rawValue];
                *error = [NSError
                    errorWithDomain:MTFThemingErrorDomain
                    code:0
                    userInfo:@{
                        NSLocalizedDescriptionKey: localizedDescription
                    }];
            }
        }
        break;
        case MTFThemeSymbolTypeClass: {
            // Locate the referenced class in the existing constants dictionary
            MTFThemeClass *classReference = classes[reference.symbol];
            if (classReference) {
                parsedConstant.mappedValue = classReference;
                continue;
            }
            // This is an invalid reference, so remove it from the resolved
            // constants
            [resolvedConstants removeObjectForKey:parsedConstant.name];
            if (error) {
                NSString *localizedDescription = [NSString stringWithFormat:
                    @"The named constant value for property '%@' ('%@') was "
                        "not found as a registered constant",
                    parsedConstant.name,
                    parsedConstant.rawValue];
                *error = [NSError
                    errorWithDomain:MTFThemingErrorDomain
                    code:0
                    userInfo:@{
                        NSLocalizedDescriptionKey: localizedDescription
                    }];
            }
        }
        break;
        default:
            NSAssert(NO, @"Unhandled symbol type");
            break;
        }
    }
    
    return [resolvedConstants copy];
}

#pragma mark Classes

- (NSDictionary *)classesParsedFromRawClasses:(NSDictionary *)rawClasses error:(NSError *__autoreleasing *)error {
    // Create MTFThemeClass objects from the raw classes
    NSMutableDictionary *parsedClasses = [NSMutableDictionary new];
    for (NSString *rawClassName in rawClasses) {
        // Ensure that the raw properties are a dictionary and not another type
        NSDictionary *rawProperties = [rawClasses
            mtf_dictionaryValueForKey:rawClassName
            error:error];
        if (!rawProperties) {
            break;
        }
        // Create a theme class from this properties dictionary
        MTFThemeClass *class = [self
            classParsedFromRawProperties:rawProperties
            rawName:rawClassName
            error:error];
        if (class) {
            parsedClasses[class.name] = class;
        }
    }
    return [parsedClasses copy];
}

- (MTFThemeClass *)classParsedFromRawProperties:(NSDictionary *)rawProperties rawName:(NSString *)rawName error:(NSError *__autoreleasing *)error {
    NSParameterAssert(rawName);
    NSParameterAssert(rawProperties);
    
    NSString *name = rawName.mtf_symbol;
    
    NSDictionary *mappedProperties = [self
        constantsParsedFromRawConstants:rawProperties
        error:error];
    
    MTFThemeClass *class = [[MTFThemeClass alloc]
        initWithName:name
        propertiesConstants:mappedProperties];
    
    return class;
}

#pragma mark Merging

- (NSDictionary *)mergeParsedConstants:(NSDictionary *)parsedConstants intoExistingConstants:(NSDictionary *)existingConstants error:(NSError *__autoreleasing *)error {
    NSSet *intersectingConstants = [existingConstants
        mtf_intersectingKeysWithDictionary:parsedConstants];
    if (intersectingConstants.count && error) {
        NSString *localizedDescription = [NSString stringWithFormat:
            @"Registering new constants with identical names to "
                "previously-defined constants will overwrite existing "
                "constants with the following names: %@",
            intersectingConstants];
        *error = [NSError
            errorWithDomain:MTFThemingErrorDomain
            code:1
            userInfo:@{
                NSLocalizedDescriptionKey : localizedDescription
            }];
    }
    NSMutableDictionary *mergedConstants = [existingConstants mutableCopy];
    [mergedConstants addEntriesFromDictionary:parsedConstants];
    return [mergedConstants copy];
}

- (NSDictionary *)mergeParsedClasses:(NSDictionary *)parsedClasses intoExistingClasses:(NSDictionary *)existingClasses error:(NSError *__autoreleasing *)error {
    NSSet *intersectingClasses = [existingClasses
        mtf_intersectingKeysWithDictionary:parsedClasses];
    if (intersectingClasses.count && error) {
        NSString *localizedDescription = [NSString stringWithFormat:
            @"Registering new classes with identical names to "
                "previously-defined classes will overwrite existing classes "
                "with the following names: %@",
            intersectingClasses];
        *error = [NSError
            errorWithDomain:MTFThemingErrorDomain
            code:1
            userInfo:@{
                NSLocalizedDescriptionKey : localizedDescription
            }];
    }
    NSMutableDictionary *mergedClasses = [existingClasses mutableCopy];
    [mergedClasses addEntriesFromDictionary:parsedClasses];
    return [mergedClasses copy];
}

static BOOL ShouldResolveReferences = YES;

+ (dispatch_queue_t)globalSettingsQueue {
    static dispatch_queue_t settingsQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        settingsQueue = dispatch_queue_create("com.erichoracek.auttheming.settingsqueue", DISPATCH_QUEUE_CONCURRENT);
    });
    return settingsQueue;
}

+ (BOOL)shouldResolveReferences {
    __block BOOL result = NO;
    dispatch_sync(self.globalSettingsQueue, ^{
        result = ShouldResolveReferences;
    });
    return result;
}

+ (void)setShouldResolveReferences:(BOOL)shouldResolveReferences {
    dispatch_barrier_async(self.globalSettingsQueue, ^{
        ShouldResolveReferences = shouldResolveReferences;
    });
}

@end
