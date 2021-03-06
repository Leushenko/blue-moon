
' Blue Moon
' JIT engine/opcodes

' this is the core of the runtime: the machine code generator and opcodes
' it's a halfway blend between JIT and interpreter: a basic JIT generates machine code
' for "unrolled" interpreter loops, theoretically (ha!) providing a speed boost
' it can also "inline" selected operations, coming closer to being a true JIT

' for now this is an Include rather than Import lib due to recursive dependency
' we'll fix that later

Rem
SuperStrict

Import "blueerror.bmx"
Import "bluevm.bmx"
Import etc etc...
End Rem

'Private	'may need to rename and open these (in the shared interface?)
Extern
	Type Stack
		Field retIP:Byte Ptr, prevBase:Stack, varp:Long Ptr, func:Bytecode, _:Long Ptr, argv:Long Ptr, retv:Long Ptr, argc:Short, retc:Short
	End Type
	Type Bytecode
		Field mcode:Byte Ptr, idMod:Int, kcount:Int, pcount:Int, upvars:Int, frameSz:Int, icount:Int, vm:Byte Ptr
	End Type
End Extern
'Public

Type BlueJIT Final
	Const PROLOGUESZ:Int = 25, ISIZE:Int = 5
	
	Global opTbl:Int(s:Stack, b:Bytecode, r:Byte Ptr)[], opc:BlueOpcode
	Global Prologue:Int[] = [ ..
		$90, $90, ..
		$8b, $44, $24, $04, ..                     'mov 4(%esp), %eax
		$89, $44, $24, $f4, ..                     'mov %eax, -12(%esp)
		$c7, $44, $24, $f8, $FF, $FF, $FF, $FF, .. 'movl ########, -8(%esp)
		$89, $64, $24, $fc, ..                     'mov %esp, -4(%esp)
		$83, $ec, $0c..                            'sub $12, %esp
	]
	
	Function Compile:Byte Ptr(vm:BlueVM, ins:Byte Ptr, icount:Int, bytecode:Bytecode)
		?Not x86
		RuntimeError "The Blue Moon JIT does not support your platform (x86-32 only at this time)"
		?
		Assert SizeOf(0:Long) = SizeOf(0:Double) And SizeOf(0:Int) = 4 And SizeOf(0:Long) = 8 And SizeOf(Byte Ptr(0)) = 4, ..
			"assumptions about platform datatype sizes are invalid"
		
		If opTbl = Null Then InitOpTbl()
		
		' compute executable code size
		Local codesize:Int = PROLOGUESZ, opPos:Int[icount]	'since sizes are irregular, looking up offsets is easiest
		For Local i:Int = 0 Until icount
			opPos[i] = codesize	'finalized below
			Select ins[i * 8]
				Case opc.SETTAB, opc.GETTAB
					codesize :+ ISIZE * 2
				Default
					codesize :+ ISIZE
			End Select
		Next
		
		' allocate executable space
		Local code:Byte Ptr = vm.mem.AllocCodeBlock(codesize)
		
		'finalize op offsets se we can look them up
		For Local i:Int = 0 Until icount
			opPos[i] :+ Int(code)	'direct to executable space
		Next
		
		' emplace prologue (used for calling in from native only)
		For Local p:Int = 0 Until PROLOGUESZ
			code[p] = Prologue[p]
		Next
		Byte Ptr Ptr(code + 14)[0] = Byte Ptr(bytecode)	'replace the ########
		
		' epilogue (shared location per-vm, probably already set)
		vm.mem.returnToNative[0] = $c30cc483	'add $12, %esp ; ret  - i.e. restore the stack to normal
		
		Local ktable:Long Ptr = Long Ptr(ins + 8 * bytecode.icount + 8 * bytecode.upvars)	'constant table
		
		' generate machine code!
		For Local i:Int = 0 Until icount	'emplace opcode calls and supporting bytecode data
			Local codep:Byte Ptr = Byte Ptr(opPos[i]), bytecodep:Byte Ptr = Byte Ptr(Int(codep) + vm.mem.PAGESZ)
			Local bi:Int = i * 8, op:Int = ins[bi], ip:Int Ptr = Int Ptr(ins + bi), func:Byte Ptr = opTbl[op]
			
			codep[0] = $e8	'call
			Byte Ptr Ptr(codep + 1)[0] = func - Int(codep + ISIZE)
			
			bytecodep[0] = ins[bi + 1] ; bytecodep[1] = ins[bi + 2]	'used by most, may get overwritten
			
			Select op
				Case opc.LOADSI, opc.CLOSURE, opc.RET, opc.POSTCALL
					Int Ptr(bytecodep + 1)[0] = ip[1]
					
				Case opc.LOADK
					Long Ptr Ptr(bytecodep + 1)[0] = ktable + ip[1]
					
				Case opc.SETTABSI, opc.GETTABSI
					Short Ptr(bytecodep)[1] = ip[1]
					
				Case opc.SETTAB, opc.GETTAB
					codep[ISIZE] = $90 ; Int Ptr(codep + ISIZE + 1)[0] = $90909090	'nops; the space is needed in the bytecode
					Long Ptr Ptr(bytecodep + 2)[0] = ktable + ip[1]
					Long Ptr Ptr(bytecodep + 2)[1] = Null	'inline cache space
					
				Case opc.GETUPV
					If Int Ptr(ins + icount * 8)[2 * bytecodep[1]] = -1
						Byte Ptr Ptr(codep + 1)[0] = Byte Ptr(BlueJIT.GETENV) - Int(codep + ISIZE)
						Byte Ptr Ptr(bytecodep + 1)[0] = Varptr(vm._ENV.val)	'note: doesn't allow _ENV to be changed from Max
					EndIf
					
				Case opc.CALL
					Short Ptr(bytecodep)[1] = ip[1]
					
				Case opc.JIF, opc.JNOT
					Int Ptr(bytecodep + 1)[0] = opPos[i + ip[1]]
					
				Case opc.JMP
					codep[0] = $e9	'use a true jump
					Int Ptr(codep + 1)[0] = opPos[i + ip[1]] - (opPos[i] + ISIZE)
					
				Default	'binary operations A = B op C
					bytecodep[2] = ip[1]
			End Select
		Next
		
		Return code
	End Function
	
	
	Const STACKFRAME_INC:Int = BlueVMMemory.STACKFRAMESZ + 4, BYTECODE_INC:Int = BlueVMMemory.BYTECODESZ + 4
	Const IP_OFFSET:Int = BlueVMMemory.PAGESZ - ISIZE
	
	
	'note: extern vars must take into account the vtbl offset, so that converting from a typed pointer can be a simple cast (faster)	
	
	Function MOV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "MOV      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		varp[rp[0]] = varp[rp[1]]
	End Function
	Function GETLC(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "GETLC    //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		varp[rp[0]] = Long Ptr Ptr(varp + rp[1])[0][0]
	End Function
	Function SETLC(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "SETLC    //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		vm.mem.Write(Long Ptr Ptr(varp + rp[0])[0], varp[rp[1]])	'unlikely but technically possible to need this
	End Function
	Function LOADK(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LOADK    //"
		Local rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET, varp:Long Ptr = stk.varp + rp[0], kp:Long Ptr = Long Ptr Ptr(rp + 1)[0]
		varp[0] = kp[0]
	End Function
	Function LOADSI(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LOADSI   //"
		Local rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local val:Int = Int Ptr(rp + 1)[0]
		Double Ptr(stk.varp)[rp[0]] = Double(val)
	End Function
	Function LOADBOOL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LOADBOOL //"
		Local rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET, vp:Int Ptr = Int Ptr(stk.varp + rp[0])
		vp[1] = BlueTypeTag.NANBOX | BlueTypeTag.BOOL
		vp[0] = Int Ptr(rp + 1)[0]
	End Function
	Function LOADNIL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LOADNIL  //"
		Local rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Int Ptr(stk.varp + rp[0])[1] = BlueTypeTag.NANBOX | BlueTypeTag.NIL
	End Function
	
	Function GETTAB(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "GETTAB   //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET, kp:Long Ptr = Long Ptr Ptr(rp + 2)[0]
		Local tabp:Byte Ptr = Byte Ptr Ptr(varp + rp[1])[0]
		If Int Ptr(varp + rp[1])[1] = BlueTypeTag.TBLBOX
			Local keyslot:Long Ptr = Null, slot:Long Ptr = BlueTable.GetSlot(tabp, kp[0], Varptr(keyslot))
			If (slot = Null) Or (keyslot[0] <> kp[0])
				If keyslot = Long Ptr(1) Then varp[rp[0]] = BlueVMMemory.NIL ; Return	'nil key
			Else
				varp[rp[0]] = slot[0] ; Return
			EndIf
		EndIf
		IndexMetamethod bc, retptr, varp + rp[0], varp[rp[1]], kp[0]	'not in table; invoke metamethod
	End Function
	Function GETTABSI(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "GETTABSI //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local tabp:Byte Ptr = Byte Ptr Ptr(varp + rp[1])[0], key:Long ; Double Ptr(Varptr(key))[0] = Short Ptr(rp)[1]
		If Int Ptr(varp + rp[0])[1] = BlueTypeTag.TBLBOX
			Local keyslot:Long Ptr = Null, slot:Long Ptr = BlueTable.GetSlot(tabp, key, Varptr(keyslot))
			If Not (slot = Null Or (keyslot And keyslot[0] <> key)) Then varp[rp[0]] = slot[0] ; Return
			If keyslot = Long Ptr(1) Then varp[rp[0]] = BlueVMMemory.NIL ; Return
		EndIf
		IndexMetamethod bc, retptr, varp + rp[0], varp[rp[1]], key
	End Function
	Function SETTAB(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "SETTAB   //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local tabvp:Byte Ptr = varp + rp[0], kp:Long Ptr = Long Ptr Ptr(rp + 2)[0]
		If Int Ptr(tabvp)[1] = BlueTypeTag.TBLBOX
			Local keyslot:Long Ptr = Null, slot:Long Ptr = BlueTable.GetSlot(Byte Ptr Ptr(tabvp)[0], kp[0], Varptr(keyslot))
			If Not (slot = Null Or keyslot[0] <> kp[0]) Then slot[0] = varp[rp[1]] ; Return
		EndIf
		NewindexMetamethod bc, retptr, varp[rp[0]], varp[rp[1]], kp[0]	'not in table; invoke metamethod or rawset
	End Function
	Function SETTABSI(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "SETTABSI //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET, tabvp:Byte Ptr = varp + rp[0]
		Local key:Long ; Double Ptr(Varptr(key))[0] = Short Ptr(rp)[1]
		If Int Ptr(tabvp)[1] = BlueTypeTag.TBLBOX
			Local keyslot:Long Ptr = Null, slot:Long Ptr = BlueTable.GetSlot(Byte Ptr Ptr(tabvp)[0], key, Varptr(keyslot))
			If Not (slot = Null Or (keyslot And keyslot[0] <> key)) Then slot[0] = varp[rp[1]] ; Return
		EndIf
		NewindexMetamethod bc, retptr, Long Ptr(tabvp)[0], varp[rp[1]], key
	End Function
	Function GETTABI(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "GETTABI  //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local tabvp:Byte Ptr = varp + rp[1], key:Long = varp[rp[2]]
		If Int Ptr(tabvp)[1] = BlueTypeTag.TBLBOX
			Local keyslot:Long Ptr = Null, slot:Long Ptr = BlueTable.GetSlot(Byte Ptr Ptr(tabvp)[0], key, Varptr(keyslot))
			If Not (slot = Null Or (keyslot And keyslot[0] <> key)) Then varp[rp[0]] = slot[0] ; Return
		EndIf
		IndexMetamethod bc, retptr, varp + rp[0], Long Ptr(tabvp)[0], key
	End Function
	Function SETTABI(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "SETTABI  //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local tabvp:Byte Ptr = varp + rp[0], key:Long = varp[rp[2]]
		If Int Ptr(tabvp)[1] = BlueTypeTag.TBLBOX
			Local keyslot:Long Ptr = Null, slot:Long Ptr = BlueTable.GetSlot(Byte Ptr Ptr(tabvp)[0], key, Varptr(keyslot))
			If Not (slot = Null Or (keyslot And keyslot[0] <> key)) Then slot[0] = varp[rp[1]] ; Return
		EndIf
		NewindexMetamethod bc, retptr, Long Ptr(tabvp)[0], varp[rp[1]], key
	End Function
	Function GETUPV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "GETUPV   //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local upvp:Byte Ptr Ptr = Byte Ptr Ptr(Byte Ptr(stk) + STACKFRAME_INC), valp:Long Ptr = Long Ptr(upvp[rp[1]])
		varp[rp[0]] = valp[0]
	End Function
	Function GETENV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)	'"unlisted" instruction: GETUPV for _ENV is translated into this at load-time
	'	Print "GETENV   //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		varp[rp[0]] = Long Ptr Ptr(rp + 1)[0][0]	'type check should not be necessary (will be handled by following op)
	End Function
	Function SETUPV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "SETUPV   //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		Local upvp:Byte Ptr Ptr = Byte Ptr Ptr(Byte Ptr(stk) + STACKFRAME_INC), valp:Long Ptr = Long Ptr(upvp[rp[0]])
		vm.mem.Write(valp, varp[rp[1]])
	End Function
	Function NEWTAB(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "NEWTAB   //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		Local tab:Byte Ptr = vm.mem.AllocTable(Null)
		Local d:Int Ptr = Int Ptr(varp + rp[0])
		d[0] = Int(tab) ; d[1] = BlueTypeTag.TBLBOX
	End Function
	Function CLOSURE(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "CLOSURE  //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		Local d:Int Ptr = Int Ptr(varp + rp[0])
		Local cbytecode:Bytecode = vm.funIndex[Int Ptr(rp + 1)[0]], upvp:Int Ptr = Int Ptr(Byte Ptr(cbytecode) + BYTECODE_INC + 8 * cbytecode.icount)
		Local closure:Byte Ptr = vm.mem.AllocClosure(cbytecode, cbytecode.upvars)	'upvars is always even (alignment)
		
		'get upvalues off the stack
		For Local u:Int = 0 Until cbytecode.upvars
			If upvp[2 * u]
				Byte Ptr Ptr(closure)[2 + u] = Byte Ptr Ptr(Byte Ptr(stk) + STACKFRAME_INC)[upvp[2 * u + 1]]
			Else
				Byte Ptr Ptr(closure)[2 + u] = Byte Ptr Ptr(varp + upvp[2 * u + 1])[0]
			EndIf
		Next
		
		d[0] = Int(closure) ; d[1] = BlueTypeTag.FUNBOX
	End Function
	Function NEWUPV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "NEWUPV   //"
		Local rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		Local upv:Byte Ptr = vm.mem.AllocObject(8, BlueTypeTag.UPV), d:Int Ptr = Int Ptr(stk.varp + rp[0])
		Long Ptr(upv)[0] = Long Ptr(d)[0]	'promote a value if it existed (useful for parameters)
		d[0] = Int(upv) ; d[1] = BlueTypeTag.NANBOX | BlueTypeTag.UPV
	End Function
	
	Function ADD(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "ADD      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0])
		Local r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.ADD, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] + Double Ptr(r)[0]
		EndIf
	End Function
	Function SUB(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "SUB      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0])
		Local r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.SUB, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] - Double Ptr(r)[0]
		EndIf
	End Function
	Function MUL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "MUL      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0])
		Local r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.MUL, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] * Double Ptr(r)[0]
		EndIf
	End Function
	Function DIV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "DIV      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0])
		Local r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.DIV, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] / Double Ptr(r)[0]
		EndIf
	End Function
	Function NMOD(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "NMOD      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0])
		Local r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.NMOD, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] Mod Double Ptr(r)[0]
		EndIf
	End Function
	Function POW(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "POW      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0])
		Local r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.POW, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] ^ Double Ptr(r)[0]
		EndIf
	End Function
	Function CAT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "CAT      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Int Ptr = Int Ptr(varp + rp[0]), r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] <> BlueTypeTag.STRBOX Or r[1] <> BlueTypeTag.STRBOX
			BinopMetamethod opc.CAT, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			l = Int Ptr Ptr(l)[0] ; r = Int Ptr Ptr(r)[0]
			Local chars:Short[l[0] + r[0]]
			For Local c:Int = 0 Until l[0]
				chars[c] = Short Ptr(l + 2)[c]
			Next
			For Local c:Int = l[0] Until l[0] + r[0]
				chars[c] = Short Ptr(r + 2)[c - l[0]]
			Next
			Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(stk.func.vm)
			Byte Ptr Ptr(d)[0] = vm.mem.AllocString(chars.Length, Short Ptr(chars))
			d[1] = BlueTypeTag.STRBOX
		EndIf
	End Function
	Function IDIV(stk:Stack, bc:Bytecode, retptr:Byte Ptr)	'integer operations aren't accessible yet so ignore them
	End Function
	Function BAND(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	End Function
	Function BOR(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	End Function
	Function BXOR(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	End Function
	Function BSHL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	End Function
	Function BSHR(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	End Function
	Function UNM(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "UNM      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Double Ptr = Double Ptr(varp + rp[0]), arg:Int Ptr = Int Ptr(varp + rp[1])
		If arg[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.UNM, bc, retptr, Long Ptr(d), Long Ptr(arg), Null	'not really worth having an UnopMetamethod
		Else
			d[0] = -Double Ptr(arg)[0]
		EndIf
	End Function
	Function LNOT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LNOT     //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Int Ptr = Int Ptr(varp + rp[0]), arg:Int Ptr = Int Ptr(varp + rp[1])
		If arg[1] = BlueTypeTag.NILBOX Or (arg[1] = BlueTypeTag.BOOLBOX And arg[0] = 0) Then d[0] = 0 Else d[0] = 1
		d[1] = BlueTypeTag.BOOLBOX
	End Function
	Function ALEN(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "ALEN     //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Long Ptr = varp + rp[0], arg:Int Ptr = Int Ptr(varp + rp[1])
		BinopMetamethod opc.ALEN, bc, retptr, d, Long Ptr(arg), Null	'len defaults to meta even if normal is possible
	End Function
	Function BNOT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)	'integer operations aren't accessible yet so ignore them
	End Function
	Function UNP(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "UNP      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Long Ptr = varp + rp[0], arg:Int Ptr = Int Ptr(varp + rp[1])
		If arg[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.UNP, bc, retptr, d, Long Ptr(arg), Null
		Else
			d[0] = Long Ptr(arg)[0]
		EndIf
	End Function
	Function EQ(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "EQ       //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Int Ptr = Int Ptr(varp + rp[0]), r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.EQ, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] = Double Ptr(r)[0] ; d[1] = BlueTypeTag.BOOLBOX
		EndIf
	End Function
	Function LT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LT       //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Int Ptr = Int Ptr(varp + rp[0]), r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.LT, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] < Double Ptr(r)[0] ; d[1] = BlueTypeTag.BOOLBOX
		EndIf
	End Function
	Function LEQ(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "LEQ      //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local d:Int Ptr = Int Ptr(varp + rp[0]), r:Int Ptr = Int Ptr(varp + rp[1]), l:Int Ptr = Int Ptr(varp + rp[2])
		If l[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX Or r[1] & BlueTypeTag.NANBOX_CHK = BlueTypeTag.NANBOX
			BinopMetamethod opc.LEQ, bc, retptr, Long Ptr(d), Long Ptr(r), Long Ptr(l)
		Else
			d[0] = Double Ptr(l)[0] <= Double Ptr(r)[0] ; d[1] = BlueTypeTag.BOOLBOX
		EndIf
	End Function
	
	Function JMP(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
		RuntimeError "wait, why are we here?"
	End Function
	Function JIF(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "JIF      //"
		Local rp:Byte Ptr = (Byte Ptr Ptr(retptr) - 4)[0] + IP_OFFSET, valp:Int Ptr = Int Ptr(stk.varp + rp[0])
		If valp[1] <> BlueTypeTag.NILBOX And Not(valp[1] = BlueTypeTag.BOOLBOX And valp[0] = 0)
			Local target:Int = Int Ptr(rp + 1)[0] ; Int Ptr(retptr)[-4] = target
		EndIf
	End Function
	Function JNOT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "JNOT     //"
		Local rp:Byte Ptr = (Byte Ptr Ptr(retptr) - 4)[0] + IP_OFFSET, valp:Int Ptr = Int Ptr(stk.varp + rp[0])
		If valp[1] = BlueTypeTag.NILBOX Or (valp[1] = BlueTypeTag.BOOLBOX And valp[0] = 0)
			Local target:Int = Int Ptr(rp + 1)[0] ; Int Ptr(retptr)[-4] = target
		EndIf
	End Function
	Function CALL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "CALL     //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local fp:Int Ptr = Int Ptr(varp + rp[0])
		If Not PrepareCall(fp, stk, rp, varp, retptr)	'PrepareCall sets everything up so there's nothing else to do to make the call happen
			'__call metamethod
		EndIf
	End Function
	Function TCALL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
		'implement this properly
		CALL(stk, bc, retptr)
	End Function
	Function RET:Byte Ptr(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "RET      //"
		Local varp:Long Ptr = stk.varp
		Local rp0:Byte Ptr = Byte Ptr Ptr(retptr)[-4], rp:Byte Ptr = rp0 + IP_OFFSET
		
		Local oldStk:Stack = stk.prevBase
		Local retv:Long Ptr = varp + rp[0]
		If oldStk
			oldStk.retv = retv
			oldStk.retc = Int Ptr(rp + 1)[0]
			Byte Ptr Ptr(retptr)[-4] = stk.retIP
			Byte Ptr Ptr(retptr)[-3] = Byte Ptr(oldStk)
			Byte Ptr Ptr(retptr)[-2] = Byte Ptr(oldStk.func) + BYTECODE_INC
		Else	'return to native code
			Local codePage:Byte Ptr = Byte Ptr(Int(rp0) & ((Int(2^12)-1) Shl 20))
			Byte Ptr Ptr(retptr)[-4] = codePage + 4
			Return retv
		EndIf
	End Function
	Function RETVA(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(stk.func.vm)
		vm.Error("vararg return not yet implemented")
	End Function
	Function POSTCALL(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
	'	Print "POSTCALL //"
		Local varp:Long Ptr = stk.varp, rp:Byte Ptr = Byte Ptr Ptr(retptr)[-4] + IP_OFFSET
		Local rneed:Int = Int Ptr(rp + 1)[0], rmin:Int = Min(rneed, stk.retc)
		For Local r:Int = 0 Until rmin
			(varp + rp[0])[r] = stk.retv[r]
		'	Print "  return " + r + ": " + Double Ptr(stk.retv)[r]
		Next
		For Local r:Int = rmin Until rneed	'nil the rest
			(varp + rp[0])[r] = BlueVMMemory.NIL
		Next
	End Function
	Function VARARG(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(stk.func.vm)
		vm.Error("varargs not yet implemented")
	End Function
	Function VAINIT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(stk.func.vm)
		vm.Error("vararg initialization not yet implemented")
	End Function
	Function CALLINIT(stk:Stack, bc:Bytecode, retptr:Byte Ptr)
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(stk.func.vm)
		vm.Error("variable-length call initialization not yet implemented")
	End Function
	
	
	Function PrepareCall:Int(fp:Int Ptr, stk:Stack, rp:Byte Ptr, varp:Long Ptr, retptr:Byte Ptr)
		If fp[1] = BlueTypeTag.NANBOX | BlueTypeTag.FUN
			Local newStk0:Stack ; Byte Ptr Ptr(Varptr(newStk0))[0] = Byte Ptr(stk) + stk.func.frameSz
			Local newStk:Stack = newStk0	'micro-opt: newStk0 can't be a register because of the unwieldy conversion
			
			newStk.retIP = Byte Ptr Ptr(retptr)[-4]
			newStk.prevBase = stk
			Local closure:Byte Ptr = Byte Ptr(fp[0])
			Local newBC:Bytecode = Bytecode Ptr(closure)[0]
			Local voff:Int = STACKFRAME_INC + 4 * newBC.upvars
			newStk.varp = Long Ptr(Byte Ptr(newStk) + voff)
			newStk.func = newBC
			
			Local argc_actual:Int = Short Ptr(rp)[1], argc_required:Int = newBC.pcount
		'	Local argc_min:Int ; If argc_actual < argc_required Then argc_min = argc_actual Else argc_min = argc_required
			Local argc_min:Int = argc_actual - argc_required ; argc_min = (argc_min & (argc_min Shr 31)) + argc_required 'branchless 32-bit Min
			
			Local argv:Long Ptr = varp + rp[1], destv:Long Ptr = newStk.varp
			For Local a:Int = 0 Until argc_min
				destv[a] = argv[a]
			'	Print "  arg " + a + ": " + argv[a]
			Next
			For Local a:Int = argc_min Until argc_required	'nil any unfilled parameters
				Int Ptr(destv + a)[1] = BlueTypeTag.NANBOX | BlueTypeTag.NIL
			Next
			newStk.argv = argv + argc_min	'argv should be to the varargs (if any)
			newStk.argc = argc_actual - argc_min	'argc is the number of varargs
			
			Local destup:Byte Ptr Ptr = Byte Ptr Ptr(Byte Ptr(newStk) + STACKFRAME_INC)
			Local upv:Byte Ptr Ptr = Byte Ptr Ptr(closure + 8)
			For Local up:Int = 0 Until newBC.upvars	'emplace upvars
				destup[up] = upv[up]
			'	Print "  upv " + up + ": " + destv[up]
			'	Print "  val: " + Double Ptr Ptr(Byte Ptr Ptr(closure) + 2 + up)[0][0]
			Next
			
			'note that the following OVERWRITE THE PARAMETERS (in release mode), so no touching stk from here on
			Byte Ptr Ptr(retptr)[-4] = newBC.mcode
			Byte Ptr Ptr(retptr)[-3] = Byte Ptr(newStk)
			Byte Ptr Ptr(retptr)[-2] = Byte Ptr(newBC) + BYTECODE_INC
			
		ElseIf fp[1] = BlueTypeTag.NANBOX | BlueTypeTag.NATFUN	'native call
			Local fun:Int(vm:BlueVM, ac:Int, av:Long Ptr, rv:Long Ptr) = Byte Ptr(fp[0])
			Local argc:Int = Short Ptr(rp)[1], argv:Long Ptr = varp + rp[1], retv:Long Ptr = Long Ptr(Byte Ptr(stk) + stk.func.frameSz)
			Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(stk.func.vm)
			stk.retc = fun(vm, argc, argv, retv)
			stk.retv = retv
		Else
			Return False	'not a function; take appropriate action
		EndIf
		Return True	'all good and will auto-call when the caller returns
	End Function
	
	Function IndexMetamethod(bc:Bytecode, retptr:Byte Ptr, d:Long Ptr, tbl:Long, key:Long)	'prep but not execute a call
		'need to work out a way to return values from this without POSTCALL (maybe can co-opt RET to handle singles by itself)
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		vm.Error("metamethod access isn't implemented yet")
	End Function
	Function NewindexMetamethod(bc:Bytecode, retptr:Byte Ptr, d:Long, val:Long, key:Long)	'as above
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
	'	vm.Error("metamethod access isn't implemented yet")
		'just rawset it for now
		'remember to handle nil key (what is correct?)
		Local tabp:Byte Ptr = Byte Ptr(Int(d))
		BlueTable.RawSet(vm.mem, tabp, key, val)
	End Function
	
	Function BinopMetamethod(op:Int, bc:Bytecode, retptr:Byte Ptr, d:Long Ptr, r:Long Ptr, l:Long Ptr)	'as above
		Local convert:BlueVM(p:Byte Ptr) = Byte Ptr(Identity), vm:BlueVM = convert(bc.vm)
		vm.Error("metamethod access isn't implemented yet")
	End Function
	
	Function InitOpTbl()
		opc = New BlueOpcode
		opTbl = [MOV, GETLC, SETLC, LOADK, LOADSI, LOADBOOL, LOADNIL, ..
			GETTAB, GETTABSI, SETTAB, SETTABSI, GETTABI, SETTABI, GETUPV, SETUPV, ..
			NEWTAB, CLOSURE, NEWUPV, ..
			ADD, SUB, MUL, DIV, NMOD, POW, CAT, ..
			IDIV, BAND, BOR, BXOR, BSHL, BSHR, ..
			UNM, LNOT, ALEN, BNOT, UNP, ..
			EQ, LT, LEQ, ..
			JMP, JIF, JNOT, CALL, TCALL, RETVA, RETVA, ..	'not a mistake: RET doesn't fit but we need the spacer
			POSTCALL, VARARG, VAINIT, CALLINIT]
		
		opTbl[opc.RET] = Byte Ptr(RET)
	End Function
	
	Function Identity:Byte Ptr(b:Byte Ptr)
		Return b
	End Function
	Function PointerToExtType:Byte Ptr(p:Byte Ptr)	'horrible pointer abuse (increment down so we can ignore the nonexistent vtbl)
		Return p - SizeOf(Byte Ptr(0))
	End Function
	Global BPtoS:Stack(p:Byte Ptr) = Byte Ptr(BlueJIT.PointerToExtType)
End Type

