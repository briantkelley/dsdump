//
//  DSXRLibrary.m
//  xref
//
//  Created by Derek Selander on 3/7/19.
//  Copyright © 2019 Selander. All rights reserved.
//

#import "DSXRLibrary.h"
#import "miscellaneous.h"
#import "DSXRLibrary.h"
#import "dyld_cache_format.h"
#import "DSXRLibrary+SymbolDumper.h"
#import "capstone/capstone.h"
#import "DSXRLibrary+Opcode.h"



@interface DSXRLibrary ()
@property (nonatomic, readonly) NSString *realizedPath;
@property (nonatomic, assign) int maxlibNameLength;
@end


extern DSXRLibrary *mainExecutable;

@implementation DSXRLibrary


- (instancetype)initWithPath:(NSString*)path
{
    self = [super init];
    if (self) {
        self.path = path;
        self.depdencies = [NSMutableArray array];
        [self.depdencies addObject:(NSString *)[NSNull null]];
        
        self.sectionCommandsArray = [NSMutableArray array];
        [self.sectionCommandsArray addObject:(NSNumber*)[NSNull null]];
        
        self.segmentCommandsArray = [NSMutableArray array];
        self.sectionCommandsDictionary = [NSMutableDictionary dictionary];
        
        self.function_starts = [NSMutableArray array];
        self.file_offset = 0;
        
        self.stringDictionary = [NSMutableDictionary dictionaryWithCapacity:200];
        self.addressDictionary = [NSMutableDictionary dictionaryWithCapacity:200];
        
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.resolvedPath]) {
            printf("No file at \"%s\"\n", [self.resolvedPath UTF8String]);
            return nil;
        }
        
        int fd = open([self.resolvedPath UTF8String], O_RDONLY);
        if (fd == -1) { perror("Couldn't open file"); return nil; }
        
        uint32 magic = 0;
        
        if (pread(fd, &magic, 4, 0) != 4) { perror("File too small"); return nil; }
    LOL:
        
        if (magic == MH_MAGIC || magic == MH_MAGIC) {
            printf("da fuck %s, %s", [self.realizedPath UTF8String], [path UTF8String]);
            assert(0);
        } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
            pread(fd, &_header, sizeof(struct mach_header_64), _file_offset);
            
            self.load_cmd_buffer = calloc(1, _header.h64.sizeofcmds);
            pread(fd, _load_cmd_buffer, _header.h64.sizeofcmds, sizeof(struct mach_header_64) + _file_offset);
            
            uintptr_t cur = (uintptr_t)_load_cmd_buffer;
            
            
            
            for (int i = 0; i < _header.h64.ncmds; i++) {
                struct load_command *ld_cmd = (struct load_command *)cur;
                
                if (ld_cmd->cmd == LC_LOAD_DYLIB || ld_cmd->cmd == LC_LOAD_WEAK_DYLIB || ld_cmd->cmd == LC_REEXPORT_DYLIB || ld_cmd->cmd == LC_LOAD_UPWARD_DYLIB) {
                    struct dylib_command *dylib_cmd = (struct dylib_command *)cur;
                    NSString * libPath = [NSString stringWithUTF8String:(char *)(cur + dylib_cmd->dylib.name.offset)];
                    [pathsSet addObject:libPath];
                    [self.depdencies addObject:libPath];
                } else if (ld_cmd->cmd == LC_BUILD_VERSION) {
                    struct build_version_command *build_version = (struct build_version_command *)cur;
                    self.build_cmd = build_version;
                }  else if (ld_cmd->cmd == LC_VERSION_MIN_IPHONEOS) {
                    self.version_cmd = (struct version_min_command *)cur;
                }  else if (ld_cmd->cmd == LC_RPATH) {
                    struct rpath_command *r_cmd = (struct rpath_command*)cur;
                    NSMutableString* rpathString = [NSMutableString stringWithUTF8String:(char *)(cur + r_cmd->path.offset)];
                    
                    [rpathSet addObject:rpathString];
                } else if (ld_cmd->cmd == LC_FUNCTION_STARTS) {
                    
                    self.function_starts_cmd = (struct linkedit_data_command *)cur;
                    void * functions = calloc(self.function_starts_cmd->datasize, 1);
                    pread(fd, functions, self.function_starts_cmd->datasize, _file_offset + self.function_starts_cmd->dataoff);
                    const uint8_t* infoStart = (uint8_t*)functions;
                    const uint8_t* infoEnd = functions + self.function_starts_cmd->dataoff;
                    uint64_t address = self.code_segment->vmaddr;
                    for(const uint8_t* p = infoStart; (*p != 0) && (p < infoEnd); ) {
                        uint64_t delta = 0;
                        uint32_t shift = 0;
                        bool more = true;
                        do {
                            uint8_t byte = *p++;
                            delta |= ((byte & 0x7F) << shift);
                            shift += 7;
                            if ( byte < 0x80 ) {
                                address += delta;
                                [self.function_starts addObject:@(address)];
                                more = false;
                            }
                        } while (more);
                    }
                    
                    free(functions);
                    
                } else if (ld_cmd->cmd == LC_SYMTAB) {
                    
                    self.symtab = calloc(1, sizeof(struct symtab_command));
                    memcpy(self->_symtab, ld_cmd, sizeof(struct symtab_command));
                    
                    self.symbols = calloc(self.symtab->nsyms, sizeof(struct nlist_64));
                    pread(fd, self.symbols, self.symtab->nsyms * sizeof(struct nlist_64), self.symtab->symoff + _file_offset);
                    
                    self.str_symbols = calloc(self.symtab->strsize, sizeof(char));
                    pread(fd, self.str_symbols, self.symtab->strsize, self.symtab->stroff + _file_offset);
                    
                } else if (ld_cmd->cmd == LC_DYLD_INFO || ld_cmd->cmd == LC_DYLD_INFO_ONLY) {
                    self.dyldinfo = (struct dyld_info_command *)ld_cmd;
                    if (xref_options.objc_only) {
                        [self parseOpcodes:fd];
                    }

                    
                } else if (ld_cmd->cmd == LC_DYSYMTAB) {
                    self.dysymtab = (struct dysymtab_command *)ld_cmd;
                    
                } else if (ld_cmd->cmd == LC_SEGMENT_64) {
             
                    [self.segmentCommandsArray addObject:@(cur)];
                    struct segment_command_64 * cmd = (struct segment_command_64 *)ld_cmd;
                    struct section_64 *sections = (struct section_64 *)(cur + sizeof(struct segment_command_64));
                    
                    if (strcmp(cmd->segname, "__TEXT") == 0) {
                        self.code_segment = cmd;
                    }
                    
                    for (int j = 0; j < cmd->nsects; j++) {
                        struct section_64 sec = sections[j];
                        char seg_buff[17] = {}; // add one more than MachO to for null terminator
                        
                        char sect_buff[17] = {};
                        memcpy(seg_buff, &sec.segname, 16);
                        memcpy(sect_buff, &sec.sectname, 16);
        
                        NSString *sectionKey = [NSString stringWithFormat:@"%s.%s", seg_buff, sect_buff];
                        
                        uintptr_t sec_ptr = (uintptr_t)&sections[j];
                        self.sectionCommandsDictionary[sectionKey] = @(sec_ptr);
                        [self.sectionCommandsArray addObject:@(sec_ptr)];
                        
                         if ( strcmp(sec.segname, "__TEXT") == 0 && strcmp(sec.sectname, "__stubs") == 0) {
                            
                            self.stubs_section = &sections[j];
                            
                        }  else if ( strcmp(sec.segname, "__TEXT") == 0 && strcmp(sec.sectname, "__stub_helper") == 0) {
                            self.stub_helper_section = &sections[j];
                            
                        } else if ( strcmp(sec.segname, "__DATA") == 0 && strcmp(sec.sectname, "__la_symbol_ptr") == 0) {
                            self.lazy_ptr_section = &sections[j]; //calloc(1, sizeof(struct section_64));

                        } else if ( strcmp(sec.segname, "__DATA") == 0 && strcmp(sec.sectname, "__cfstring") == 0) {
//                            self.lazy_ptr_section = &sections[j];
                            self.cfstring_buffer = calloc(1, (long)&sections[j].size);
                        } else if ( strcmp(sec.sectname, "__objc_classrefs__DATA") == 0) {
                            // sectname uses the full 16 bytes, so include segment (no null terminator)
                            
                            sec.size / sizeof(void*);

                            
                        } else if ( strcmp(sec.sectname, "__objc_classlist__DATA") == 0) {
                            // sectname uses the full 16 bytes, so include segment (no null terminator)
                            
                            sec.size / sizeof(void*);
                            
                            
                        }
                        
                    }
                    //                    }
                    
                } else if (ld_cmd->cmd == LC_UUID) {
                    self.uuid_cmd = calloc(1, sizeof(struct uuid_command));
                    memcpy(self->_uuid_cmd, ld_cmd, sizeof(struct uuid_command));
                } else if (ld_cmd->cmd == LC_FUNCTION_STARTS) {
                    
                }
                cur += ld_cmd->cmdsize;
            }
            
        } else if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            
            struct fat_header fatHeader ;
            pread(fd, &fatHeader, sizeof(struct fat_header), 0);
            uint32_t numArchs = htonl(fatHeader.nfat_arch);
            
            
            struct fat_arch *arches = calloc(numArchs, sizeof(struct fat_arch));
            pread(fd, arches, sizeof(struct fat_arch) * numArchs, sizeof(struct fat_header));
            
            for (int j = 0; j < numArchs; j++) {
                if (arches[j].cputype == 0x07000001) {
                    _file_offset = htonl(arches[j].offset);
                    pread(fd, &magic, 4, _file_offset);
                    free(arches);
                    goto LOL;
                }
                
            }
            
            assert(0);
            free(arches);
            
        } else if (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
            struct fat_arch_64 fatHeader;
            pread(fd, &fatHeader, sizeof(struct fat_header), 0);
            assert(0);
        }
        
        if (self.lazy_ptr_section && self.dysymtab) {
            uintptr_t syms = (_file_offset + self.dysymtab->indirectsymoff);
            _indirect_symbols.count = self.dysymtab->nindirectsyms;
            _indirect_symbols.indirect_sym = calloc(self.indirect_symbols.count, sizeof(uint32_t));
             pread(fd, _indirect_symbols.indirect_sym, _indirect_symbols.count * sizeof(uint32_t), syms);
        }
        close(fd);
    }
    
    [exploredSet addObject:path];
    

//    Had this for print formatting, dunno of you still want it though for future idea...
//    for (int i = 1; i < self.depdencies.count; i++) {
//
//        _maxlibNameLength =  MAX((int)self.depdencies[i].length, _maxlibNameLength);
//    }
    if (!self.symtab) {
        printf("Warning: no symbol table\n");
        return nil;
    }
    
    return self;
}


- (NSString *)resolvedPath {
    if (_realizedPath) {
        return _realizedPath;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.path]) {
        _realizedPath = self.path;
        return _realizedPath;
    }
    
    if ([self.path hasPrefix:@"@rpath"] && mainExecutable) {
        
        static dispatch_once_t once;
        static NSString *executablePath = nil;
        dispatch_once(&once, ^{
            executablePath = [mainExecutable.path stringByDeletingLastPathComponent];
        });
        
        NSString *rpathReplacement = nil;
        for (NSString *potentialPath in rpathSet) {
            if ([potentialPath hasPrefix:@"@loader_path"]) {
                rpathReplacement = [potentialPath stringByReplacingOccurrencesOfString:@"@loader_path" withString:executablePath];
            } else if ([potentialPath hasPrefix:@"@executable_path"]) {
                rpathReplacement = [potentialPath stringByReplacingOccurrencesOfString:@"@executable_path" withString:executablePath];
            }
            
            
            NSString *realizedPath = [self.path stringByReplacingOccurrencesOfString:@"@rpath" withString:rpathReplacement];
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:realizedPath]) {
                _realizedPath = realizedPath;
                return realizedPath;
            }
        }
        
        return [self.path stringByReplacingOccurrencesOfString:@"@rpath" withString:[mainExecutable.path stringByDeletingLastPathComponent]];
        
        // Still can't find it... try simulator then try dyld shared cache
    } else if (YES ) {//|| [self isSimulatorLibrary] || [mainExecutable isSimulatorLibrary]) {
        _realizedPath = [[self simulatorPath] stringByAppendingPathComponent:self.path];
        return _realizedPath;
    }
    
    return self.path;
}


//- (BOOL)isSimulatorLibrary {
//    if (!self.build_cmd) { return NO; }
//    uint32_t platform = self.build_cmd->platform;
//    if (platform == PLATFORM_IOSSIMULATOR || platform == PLATFORM_TVOSSIMULATOR || platform == PLATFORM_WATCHOSSIMULATOR) {
//        return YES;
//    }
//    return NO;
//}

- (NSString *)simulatorPath {
    NSString *cachePath;
    //    switch (self.build_cmd->platform) {
    //        case PLATFORM_IOSSIMULATOR:
    cachePath = @"/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/";
    //    }
    
    assert(cachePath);
    return cachePath;
}

- (NSString *)dyldSharedCachePath {
    
    NSString *cachePath;
    switch (self.build_cmd->platform) {
        case PLATFORM_MACOS:
            cachePath = @"/private/var/db/dyld/dyld_shared_cache_x86_64h";
            break;
        case PLATFORM_IOS:
            cachePath = @"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm";
            break;
        case PLATFORM_TVOS:
            
            break;
        case PLATFORM_WATCHOS:
            
            break;
        case PLATFORM_BRIDGEOS:
            
            break;
        case PLATFORM_IOSMAC:
            
            break;
        case PLATFORM_IOSSIMULATOR:
            cachePath = @"/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/";
            break;
        case PLATFORM_TVOSSIMULATOR:
            
            break;
        case PLATFORM_WATCHOSSIMULATOR:
            
            break;
            
        default:
            break;
    }
    //    if (self.build_cmd->platform == PLATFORM_MACOS) {
    //
    //    }
    return nil;
}

- (NSArray *)searchNonTextAddresses:(uintptr_t)address {
    NSMutableArray *foundAddresses = [NSMutableArray array];
    
    int fd = open(self.realizedPath.UTF8String, O_RDONLY);
    
    for (int i = 1; i < self.sectionCommandsArray.count; i++) {
        
        struct section_64 *section = (struct section_64 *)self.sectionCommandsArray[i].longValue;
        if (!section->offset) { continue; }
        if (section->flags & S_LITERAL_POINTERS || section->flags == S_REGULAR) {
            
            uintptr_t *base = calloc(1, section->size);
            size_t count = (uintptr_t)section->size / sizeof(uintptr_t);
            pread(fd, base, section->size, section->offset + self.file_offset);
            for (int z = 0; z < count; z++) {
                if (address == base[z]) {
                    [foundAddresses addObject:@((z * sizeof(uintptr_t)) + section->addr)];
                }
            }
            free(base);
        }
    }
    close(fd);
    return foundAddresses;
}

- (void)dumpReferencesForAddress:(uintptr_t)address {
    
    printf("Searching for references to: %s%p%s\n", dcolor(DSCOLOR_CYAN), (void*)address, colorEnd());
    NSArray <NSNumber *>*foundAddresses = nil;
    if (self.header.h64.cputype == CPU_TYPE_ARM64) {
        foundAddresses = [self findAddressInCode_ARM64:address];
    } else {
        foundAddresses = [self findAddressInCode_x86:address];
    }
    
    if (xref_options.all_sections) {
        foundAddresses = [foundAddresses arrayByAddingObjectsFromArray:[self searchNonTextAddresses:address]];
    }
    
    if ([foundAddresses count] == 0) {
        printf("Couldn't find any references to \"0x%011lx\"\n", address);
    } else {
        [self printFunctionsContainingAddresses:foundAddresses];
    }
}


- (void)dumpReferencesForFileOffset:(uintptr_t)file_offset {
    uintptr_t resolvedAddress = 0;
    for (NSNumber *s in self.segmentCommandsArray) {
        if ([s isEqual:[NSNull null]]) { continue; }
        struct segment_command_64 *seg = (struct segment_command_64 *)s.longValue;
        uintptr_t start = seg->fileoff;
        uintptr_t stop = seg->filesize + start;
        
        if (file_offset >= start && file_offset <= stop) {
            
            struct section_64 *cur = (struct section_64 *)(s.longValue + sizeof(struct segment_command_64));
            for (int i = 0; i < seg->nsects; i++) {
                struct section_64 sec = cur[i];
                
                uintptr_t sec_start = sec.offset;
                uintptr_t sec_stop = sec.size + sec_start;
                
                if (file_offset >= sec_start && file_offset < sec_stop) {
                    resolvedAddress = seg->vmaddr + file_offset;
                    printf("Found file offset 0x%0lx in %s0x%011lx%s in %s%s,%s%s\n", file_offset,  dcolor(DSCOLOR_CYAN), resolvedAddress, colorEnd(), dcolor(DSCOLOR_YELLOW), sec.segname, sec.sectname, colorEnd());
                    break;
                }
            }
        }
    }
    
    NSArray <NSNumber*> *foundAddresses = nil;
    
    if (!resolvedAddress) {
        printf("Couldn't find address 0x%lx\n", resolvedAddress);
    } else if (self.header.h64.cputype == CPU_TYPE_ARM64) {
        foundAddresses = [self findAddressInCode_ARM64:resolvedAddress];
    } else if (self.header.h64.cputype == CPU_TYPE_X86_64) {
        foundAddresses = [self findAddressInCode_x86:resolvedAddress];
    } else {
        printf("cputype 0x%x not supported... womp womp\n", self.header.h64.cputype);
        return;
    }
    
    
    if (xref_options.all_sections) {
        foundAddresses = [foundAddresses arrayByAddingObjectsFromArray:[self searchNonTextAddresses:resolvedAddress]];
    }
    
    if ([foundAddresses count] == 0) {
        printf("Couldn't find any references to \"0x%011lx\"\n", resolvedAddress);
    } else {
        [self printFunctionsContainingAddresses:foundAddresses];
    }
    //    if (!resolvedAddress) { printf("Couldn't resolve offset %d\n", file_offset); return ;}
    
    
}

- (void)dumpReferencesForSymbol:(NSString *)symbol {
    const char *search_symbol = [symbol UTF8String];
    struct nlist_64 *foundSymbol = NULL;
    for (int i = 0; i < self.symtab->nsyms; i++) {
        char * symbol_name = &self.str_symbols[self.symbols[i].n_un.n_strx];
        if (strcmp(symbol_name, search_symbol) == 0 || strcmp(&symbol_name[1], search_symbol) == 0) {
            foundSymbol = &self.symbols[i];
            break;
        }
    }
    
    
    if (!foundSymbol) {
        printf("Couldn't find symbol %s\"%s\"%s in symbol table\n", dcolor(DSCOLOR_RED), search_symbol, colorEnd());
        return;
    }
    
    printf("Searching for: ");
    [self printSymbol:foundSymbol];
    
    // It's in the symbol table, so now see what exactly it is
    uintptr_t resolvedAddress = 0;
    if ((foundSymbol->n_type & N_TYPE) == N_SECT) {
        resolvedAddress = foundSymbol->n_value;
    } else {
        resolvedAddress = [self externalSymbolStubAddress:symbol];
    }
    
    if (resolvedAddress == 0) {
        printf("Couldn't find symbol %s\"%s\"%s in code...\n", dcolor(DSCOLOR_RED), search_symbol, colorEnd());
        return;
    }
    
    // Is the symbol implemented in this module or elsewhere
    BOOL isInternal = ((foundSymbol->n_type & N_TYPE) == N_SECT);
    NSArray *foundAddresses = nil;
    if (self.header.h64.cputype == CPU_TYPE_ARM64) {
        uintptr_t resolvedStub = isInternal ? resolvedAddress : [self findStub_ARM64:resolvedAddress];
        if (!resolvedStub) {
            printf("Couldn't find symbol %s\"%s\"%s in code...\n", dcolor(DSCOLOR_RED), search_symbol, colorEnd());
            return;
        }
        
        foundAddresses = [self findAddressInCode_ARM64:resolvedStub];
    } else if (self.header.h64.cputype == CPU_TYPE_X86_64) {
        
        uintptr_t resolvedStub = isInternal ? resolvedAddress : [self findStub_x86_64:resolvedAddress];
        foundAddresses = [self findAddressInCode_x86:resolvedStub];
    } else {
        printf("cputype 0x%x not supported... womp womp\n", self.header.h64.cputype);
        return;
    }
    if ([foundAddresses count] == 0) {
        printf("Couldn't find any references to \"%s\"\n", search_symbol);
    } else {
        [self printFunctionsContainingAddresses:foundAddresses];
    }
}


/********************************************************************************
//  Find internal methods
********************************************************************************/

- (NSArray <NSNumber*> *)findAddressInCode_x86:(uintptr_t)address {
    NSMutableArray <NSNumber*>*foundAddresses = [NSMutableArray array];
    if (!self.instructions) { [mainExecutable parseData]; }
    
    size_t count = self.instructions_count;
    
    for (int i = 0; i < count; i++) {
        cs_insn insn =  _instructions[i];
        if (!insn.detail) { continue; }
        cs_x86_op *ops = insn.detail->x86.operands;
        
        for (int z = 0; z < insn.detail->x86.op_count; z++) {
            cs_x86_op op = ops[z];
            if (op.type == X86_OP_INVALID) { break; }
            
            if (op.type == X86_OP_MEM && op.mem.base == X86_REG_RIP && ( op.mem.disp + insn.address + insn.size)  == address) {
                [foundAddresses addObject:@(insn.address)];
            } else if (op.type == X86_OP_IMM && op.imm == address && insn.id == X86_INS_CALL)  {
                [foundAddresses addObject:@(insn.address)];
            }
        }
    }
    
    return foundAddresses;
}

- (NSArray <NSNumber *>*)findAddressInCode_ARM64:(uintptr_t)address {
    if (!self.instructions) { [mainExecutable parseData]; }
    NSMutableArray <NSNumber*> *foundAddresses = [NSMutableArray array];
    size_t count = self.instructions_count;
    
    for (int i = 0; i < count; i++) {
        cs_insn insn =  _instructions[i];
        if (!insn.detail) { continue; }
        cs_insn *insn_next = NULL;
        if (i < count - 1) {
            insn_next = &_instructions[i + 1];
        }
        cs_arm64_op *ops = insn.detail->arm64.operands;

        // Found an ADRP, ADD combo..., let's make sure it's the same affected register
        if (insn.id == ARM64_INS_ADRP && insn_next && insn_next->id == ARM64_INS_ADD) {
            assert(insn.detail->arm64.op_count == 2);
            
            cs_arm64_op first_op = ops[0];
            cs_arm64_op second_op = ops[1];
            
            arm64_reg reg = first_op.reg;
            uint64_t imm = second_op.imm;
            
            assert(first_op.type == ARM_OP_REG && second_op.type == ARM64_OP_IMM);
            assert(insn_next->detail->arm64.op_count == 3);
            cs_arm64_op first_op_next = insn_next->detail->arm64.operands[0];
            cs_arm64_op second_op_next = insn_next->detail->arm64.operands[1];
            cs_arm64_op third_op_next = insn_next->detail->arm64.operands[2];
            
            if (first_op_next.type == ARM_OP_REG && reg != first_op_next.reg && reg != second_op_next.reg && third_op_next.type != ARM64_OP_IMM)  {
                continue;
            }
            
            imm += third_op_next.imm;
            if (imm == address) {
                [foundAddresses addObject:@(insn_next->address)];
            }
        } else if (insn.id == ARM64_INS_BL || insn.id == ARM64_INS_B) {
            if (ops[0].type == ARM64_OP_IMM && ops[0].imm == address) {
                [foundAddresses addObject:@(insn.address)];
            }
        }
    }
    
    return foundAddresses;
}


- (uintptr_t)findStub_x86_64:(uintptr_t)stubAddress {
    
    void* buf = calloc(sizeof(char), self.stubs_section->size);
    int fd = open(self.realizedPath.UTF8String, O_RDONLY);
    pread(fd, buf, self.stubs_section->size, self.stubs_section->offset + self.file_offset);
    
    
    cs_insn *instructions = NULL;
    csh handle = 0;
    int err = cs_open(CS_ARCH_X86, CS_MODE_64, &handle);
    if (err != CS_ERR_OK) {
        assert(NO);
    }
    
    //    struct platform platforms;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);
    
    size_t count = cs_disasm(handle, buf, self.stubs_section->size, self.stubs_section->addr, 0, &instructions);
    
    if (count == 0) {
        printf("error!! %d\n", cs_errno(handle));
        
    }
    for (int i = 0; i < count; i++) {
        cs_insn insn =  instructions[i];
        if (!insn.detail || insn.id  != X86_INS_JMP || insn.detail->x86.operands[0].type != X86_OP_MEM) { continue; }
        
        if (insn.detail->x86.operands[0].mem.disp + insn.address + insn.size == stubAddress) {
            return insn.address;
        }
        
        
        
    }


    close(fd);
    return 0;
    
}

- (uintptr_t)findStub_ARM64:(uintptr_t)stubAddress {
    
    void* buf = calloc(sizeof(char), self.stubs_section->size);
    int fd = open(self.realizedPath.UTF8String, O_RDONLY);
    pread(fd, buf, self.stubs_section->size, self.stubs_section->offset + self.file_offset);
    
    
    cs_insn *instructions = NULL;
    csh handle = 0;
    int err = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &handle);
    if (err != CS_ERR_OK) {
        assert(NO);
    }
    
    //    struct platform platforms;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);

    //    size_t code_size = self.code_section->size;
    //    uint64_t out_address = self.code_section->addr;
    
    size_t count = cs_disasm(handle, buf, self.stubs_section->size, self.stubs_section->addr, 0, &instructions);
    
    if (count == 0) {
        printf("error!! %d\n", cs_errno(handle));
        
    }
    for (int i = 0; i < count; i++) {
        cs_insn insn =  instructions[i];
        if (!insn.detail || insn.id  != ARM64_INS_LDR || insn.detail->arm64.operands[1].type != ARM_OP_IMM) { continue; }
        
        
        
        if (insn.detail->arm64.operands[1].imm == stubAddress) {
            return insn.address - insn.size;
        }
    }

    

    close(fd);
    return 0;
}

- (void)printFunctionsContainingAddresses:(NSArray <NSNumber*>*)addresses {
    
    
    
    // TODO, optimize this, linear search Derbear? C'mon...
    for (int i = 0; i < addresses.count; i++) {
        
        uintptr_t cur = addresses[i].longValue;
        
        uintptr_t func_count = self.function_starts.count;
        for (int j = 0; j < func_count; j++) {
            uintptr_t start =  self.function_starts[j].longValue;
            uintptr_t stop =  j >= func_count - 1 ? UINTPTR_MAX :  self.function_starts[j + 1].longValue;
            
            if (start <= cur && cur <= stop && stop != -1) {
                BOOL found_symbol_name = NO;
                printf(" 0x%011lx + %-5lu (0x%011lx)", start, cur - start, cur);
                for (int z = 0; z < self.symtab->nsyms; z++) {
                    char * chr = &self.str_symbols[self.symbols[z].n_un.n_strx];
                    if (self.symbols[z].n_value == start  && strlen(chr) > 1) {
                        
                        printf(" %s%s%s\n", dcolor(DSCOLOR_CYAN), &self.str_symbols[self.symbols[z].n_un.n_strx], colorEnd());
                        
                        found_symbol_name = YES;
                        break;
                    }
                }
                // Found where it resides in, but couldn't obtain the name...
                if (!found_symbol_name) {
                    printf(" %s___lldb_unnamed_symbol%d$$%s%s\n", dcolor(DSCOLOR_CYAN), j + 1, [[self.path lastPathComponent] UTF8String], colorEnd());
                    
                }
            }
            
        }
        
        if (xref_options.all_sections) {
            
            
            for (int i = 1; i < self.sectionCommandsArray.count; i++) {
                struct section_64 *section = (struct section_64 *)self.sectionCommandsArray[i].longValue;
                
                if (strcmp(section->sectname, "__text") != 0 && section->addr <= cur && cur < (section->addr + section->size)) {
                    printf("%s%s,%s%s %s%p%s\n", dcolor(DSCOLOR_YELLOW), section->segname, section->sectname, colorEnd(),  dcolor(DSCOLOR_CYAN), (void*)cur, colorEnd());
                }
            }
            
            
        }
        
    }
}




- (uintptr_t)externalSymbolStubAddress:(NSString *)symbol {
    
    const char *searched_symbol = [symbol UTF8String];

    size_t count  = (self.lazy_ptr_section->size / (1 << self.lazy_ptr_section->align));
    
    int start = self.lazy_ptr_section->reserved1;
    for (int i = 0; i < count; i++) {
        int offset = self.indirect_symbols.indirect_sym[i + start];
        
        // If stripped' local symbol, you're not gonna find it by name
        if (INDIRECT_SYMBOL_LOCAL & offset) { continue; }
        
        struct nlist_64 sym = self.symbols[offset];
        char * chr = &self.str_symbols[sym.n_un.n_strx];

        if (strcmp(chr, searched_symbol) == 0 || strcmp(&chr[1], searched_symbol) == 0 ) {
            uintptr_t buf_stub_helper;
            int fd = open(self.realizedPath.UTF8String, O_RDONLY);
            pread(fd, &buf_stub_helper, sizeof(uintptr_t), self.file_offset + self.lazy_ptr_section->offset + (8 * i));
            
    
            close(fd);
            return self.lazy_ptr_section->addr + (8 * i);
            return buf_stub_helper;
        }
    }
    
    return 0;
}


/********************************************************************************
// Helper debugging methods 
********************************************************************************/

- (NSString *)description {
    return [NSString stringWithFormat:@"(%p) %@", self, self.realizedPath];
}

- (NSUInteger)hash {
    return [self.path hash];
}

@end
