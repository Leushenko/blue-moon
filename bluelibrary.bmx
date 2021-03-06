
' Blue Moon
' Basic Lua library

' this is the minimal "standard library", designed to be loaded into a VM on start
' most of this doesn't use the convenience interface so as to keep overhead down

' for now this is an Include rather than Import lib due to recursive dependency
' we'll fix that later

Rem
SuperStrict

Import "blueerror.bmx"
Import "bluevm.bmx"
Import "bluetable.bmx"
End Rem

Type BlueBasicLibrary
	Function _Load(vm:BlueVM, _ENV:BlueLuaVal)
		_ENV.Set("_G", _ENV)
		_ENV.Set("getmetatable", vm.ValueFromFunction(getmetatable))
		_ENV.Set("print", vm.ValueFromFunction(_print))
		_ENV.Set("rawget", vm.ValueFromFunction(rawget))
		_ENV.Set("rawset", vm.ValueFromFunction(rawset))
		_ENV.Set("setmetatable", vm.ValueFromFunction(setmetatable))
		_ENV.Set("tonumber", vm.ValueFromFunction(tonumber))
		_ENV.Set("tostring", vm.ValueFromFunction(_tostring))
		_ENV.Set("type", vm.ValueFromFunction(_type))
		Local vs:Byte Ptr = vm.mem.AllocConstStr(_VERSION)
		_ENV.Set("_VERSION", vm.ValueFromLua(vs, BlueTypeTag.STRBOX))
	End Function
	
	'assert
	'collectgarbage
	'dofile
	'error
	Function getmetatable:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 1 Then vm.Error("not enough arguments to getmetatable: expecting object(1)")
		Local tag:Int = Int Ptr(argv)[1]
		If tag = BlueTypeTag.TBLBOX Or tag = BlueTypeTag.USRBOX
			Local meta:Int = Int Ptr Ptr(argv)[0][0]
			If meta
				Int Ptr(retv)[1] = BlueTypeTag.TBLBOX
				Int Ptr(retv)[0] = meta
			Else
				retv[0] = vm.mem.NIL
			EndIf
		Else
			retv[0] = vm.mem.NIL
		EndIf
		Return 1
	End Function
	'ipairs
	'load
	'loadfile
	'next
	'pairs
	'pcall
	Function _print:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		For Local i:Int = 0 Until argc
			Local val:Long = vm.mem.AnyToString(argv[i])	'this really shouldn't be in mem
			Print vm.mem.ValToMaxString(val)
		Next
		Return 0
	End Function
	'rawequal
	Function rawget:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 2 Then vm.Error("not enough arguments to rawget: expecting table(1) and key(2)")
		Local tag:Int = Int Ptr(argv)[1]
		If tag = BlueTypeTag.TBLBOX
			retv[0] = BlueTable.RawGet(Byte Ptr Ptr(argv)[0], argv[1])
		Else
			vm.Error("argument (1) to rawget must be a table")
		EndIf
		Return 1
	End Function
	'rawlen
	Function rawset:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 3 Then vm.Error("not enough arguments to rawset: expecting table(1), key(2), value(3)")
		Local tag:Int = Int Ptr(argv)[1]
		If tag = BlueTypeTag.TBLBOX
			BlueTable.RawSet(vm.mem, Byte Ptr Ptr(argv)[0], argv[1], argv[2])
			retv[0] = argv[0]
		Else
			vm.Error("argument (1) to rawset must be a table")
		EndIf
		Return 1
	End Function
	'select
	Function setmetatable:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 2 Then vm.Error("not enough arguments to setmetatable: expecting object(1) and metatable(2)")
		Local tag:Int = Int Ptr(argv)[1]
		If tag = BlueTypeTag.TBLBOX Or tag = BlueTypeTag.USRBOX
			'check if existing metatable has __metatable field and error if so
			tag = Int Ptr(argv + 1)[1]
			If tag <> BlueTypeTag.TBLBOX Then vm.Error("argument (2) to setmetatable must be a table")
			'apply finalizer tag
			'apply weakness flag
			Int Ptr Ptr(argv)[0][0] = Int Ptr(argv + 1)[0]
		EndIf
		retv[0] = argv[0]	'manual doesn't say it's an error to not be a table
		Return 1
	End Function
	Function tonumber:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 1 Then vm.Error("not enough arguments to tonumber: expecting object(1)")
		If argc >= 2
			vm.Error("haven't implemented multiple bases yet")
		Else
			Local tag:Int = Int Ptr(argv)[1], s:String
			Select tag
				Case BlueTypeTag.STRBOX
					retv[0] = vm.mem.ValToMaxString(argv[0]).ToDouble()	'woeful!
				Case BlueTypeTag.NILBOX, BlueTypeTag.BOOLBOX, BlueTypeTag.FUNBOX, BlueTypeTag.NATFUNBOX, ..
				     BlueTypeTag.USRBOX, BlueTypeTag.THRBOX, BlueTypeTag.TBLBOX
					retv[0] = vm.mem.NIL
				Default
					retv[0] = argv[0]
			End Select
		EndIf
		Return 1
	End Function
	Function _tostring:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 1 Then vm.Error("not enough arguments to tostring: expecting object(1)")
		'if meta has __tostring
		'else
		Local val:Long = vm.mem.AnyToString(argv[0])	'this really shouldn't be in mem
		'endif
		retv[0] = val
		Return 1
	End Function
	Function _type:Int(vm:BlueVM, argc:Int, argv:Long Ptr, retv:Long Ptr)
		If argc < 1 Then vm.Error("not enough arguments to type: expecting object(1)")
		Local tag:Int = Int Ptr(argv)[1], s:String
		Select tag
			Case BlueTypeTag.STRBOX ; s = "string"
			Case BlueTypeTag.NILBOX ; s = "nil"
			Case BlueTypeTag.BOOLBOX ; s = "boolean"
			Case BlueTypeTag.FUNBOX, BlueTypeTag.NATFUNBOX ; s = "function"
			Case BlueTypeTag.USRBOX ; s = "userdata"
			Case BlueTypeTag.THRBOX ; s = "thread"
			Case BlueTypeTag.TBLBOX ; s = "table"
			Default	 ; s = "number"
		End Select
		Local sp:Short Ptr = s.ToWString()
		Byte Ptr Ptr(retv)[0] = vm.mem.AllocString(s.Length, sp)
		MemFree(sp)
		Int Ptr(retv)[1] = BlueTypeTag.STRBOX
		Return 1
	End Function
	Const _VERSION:String = "Lua 5.3 (incomplete)"
	'xpcall
End Type

