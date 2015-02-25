
' Blue Moon
' Lua-table implementation


SuperStrict

Import "blueallocator.bmx"


Private
Extern
	Function frexp:Double(d:Double, Exp:Int Ptr) = "frexp"
End Extern
Public

Type BlueTable Final
	Function Get:Long(tbl:Byte Ptr, key:Long)
		Local tag:Int = Int Ptr(Varptr(key))[1], idx:Int
		
		If tag = BlueTypeTag.NANBOX | BlueTypeTag.STR	'string - common case
			idx = Int Ptr(Int(key))[1]
		ElseIf tag & BlueTypeTag.NANBOX_CHK <> BlueTypeTag.NANBOX	'number
			Local d:Double ; Long Ptr(Varptr(d))[0] = key ; idx = Abs Int(d)
			If d = idx	'int key
				Local arr:Byte Ptr = Byte Ptr Ptr(tbl)[3]
				If arr And idx < Int Ptr(arr)[-1] Then Return Long Ptr(arr)[idx]	'if this is nil, it won't be in the hash part anyway
			Else
				d = frexp(d, Varptr(idx)) * ($7fffffff - 1024)	'INT_MAX - DBL_MAX_EXP
				idx = Abs(idx) + Int(d)
			EndIf
		ElseIf tag = BlueTypeTag.NANBOX | BlueTypeTag.NIL	'nil -> nil
			Return key
		Else	'pointer (needs improvement)
			idx = Int(key) Shr 3
		EndIf
		
		Local hashpart:Byte Ptr = Byte Ptr Ptr(tbl)[2]
		If hashpart
			Local hsize:Int = 1 Shl Int Ptr(hashpart)[-1]
			idx = idx & (hsize - 1)	'apparently this is faster than Mod
			For Local i:Int = idx Until hsize	'naive linear probe
				If Long Ptr(hashpart)[2 * i] = key Then Return Long Ptr(hashpart)[2 * i + 1]
			Next
			For Local i:Int = 0 Until idx	'yep
				If Long Ptr(hashpart)[2 * i] = key Then Return Long Ptr(hashpart)[2 * i + 1]
			Next
		EndIf
		
		Local ret:Long ; Int Ptr(Varptr(ret))[1] = BlueTypeTag.NANBOX | BlueTypeTag.NIL	'why can't i shift longs?
		Return ret
	End Function
	
	Function Set(mem:BlueVMMemory, tbl:Byte Ptr, key:Long, val:Long)
		Local tag:Int = Int Ptr(Varptr(key))[1], idx:Int, slot:Long Ptr = Null
		
		If tag = BlueTypeTag.NANBOX | BlueTypeTag.NIL Then Return	'nil is not a valid key
		
		If tag & BlueTypeTag.NANBOX_CHK <> BlueTypeTag.NANBOX	'if key is an int and less than arraylength
			Local d:Double ; Long Ptr(Varptr(d))[0] = key ; idx = Abs Int(d)
			If d = idx
				Local arraypart:Byte Ptr = Byte Ptr Ptr(tbl)[3]
				If arraypart <> Null And idx < Int Ptr(arraypart)[-1] Then slot = Long Ptr(arraypart) + idx
			EndIf
		EndIf
		If slot = Null	'elsewise if hashcount < hashsize
			Local hashpart:Byte Ptr = Byte Ptr Ptr(tbl)[2]
			If hashpart <> Null
				Local hsize:Int = 1 Shl Int Ptr(hashpart)[-1]
				If Int Ptr(hashpart)[-2] < hsize	'there's a slot free somewhere
					
					If tag = BlueTypeTag.NANBOX | BlueTypeTag.STR	'string - common case
						idx = Int Ptr(Int(key))[1]
					ElseIf tag & BlueTypeTag.NANBOX_CHK <> BlueTypeTag.NANBOX	'non-integer
						Local d:Double ; Long Ptr(Varptr(d))[0] = key
						d = frexp(d, Varptr(idx)) * ($7fffffff - 1024)	'INT_MAX - DBL_MAX_EXP
						idx = Abs(idx) + Int(d)
					Else	'pointer
						idx = Int(key) Shr 3
					EndIf
					
					idx = idx & (hsize - 1)	'fastmod
					For Local i:Int = idx Until hsize
						If Long Ptr(hashpart)[2 * i] = key Then slot = Long Ptr(hashpart) + (2 * i + 1)
					Next
					For Local i:Int = 0 Until idx
						If Long Ptr(hashpart)[2 * i] = key Then slot = Long Ptr(hashpart) + (2 * i + 1)
					Next
					
				EndIf
			EndIf
		EndIf
		
		If slot = Null
			Resize(mem, tbl, key) ; Set Null, tbl, key, val
		Else
			mem.Write(slot, val)
		EndIf
	End Function
	
	Function Resize(mem:BlueVMMemory, tbl:Byte Ptr, key:Long)
		Local hashpart:Byte Ptr = Byte Ptr Ptr(tbl)[2], arraypart:Byte Ptr = Byte Ptr Ptr(tbl)[3]
		Const NILTAG:Int = BlueTypeTag.NANBOX | BlueTypeTag.NIL
		
		Local asize:Int = 0, tsize:Int = 0, numcount:Int[32]
		If arraypart	'compute new array size
			If Int Ptr(arraypart)[1] <> NILTAG Then numcount[0] = 1
			Local cell:Int = 1, cellp2:Int = 2 ^ cell
			For Local i:Int = 1 Until Int Ptr(arraypart)[-1]
				If i >= cellp2 Then cell :+ 1 ; cellp2 = 2 ^ cell
				If Int Ptr(arraypart)[i * 2 + 1] <> NILTAG Then numcount[cell] :+ 1
			Next
		EndIf
		If hashpart
			For Local i:Int = 0 Until Int Ptr(hashpart)[-2]
				Local tag2:Int = Int Ptr(hashpart)[i * 4 + 1]
				If tag2 & BlueTypeTag.NANBOX_CHK <> BlueTypeTag.NANBOX
					Local d:Double = Double Ptr(hashpart)[i * 2]
					If d = Abs Int(d) Then numcount[Ceil(Log(d + 1) / Log(2))] :+ 1 Else tsize :+ 1
				Else
					tsize :+ 1	'get started on new table size
				EndIf
			Next
		EndIf
		Local tag:Int = Int Ptr(Varptr(key))[1]	'add key to the appropriate one
		If tag & BlueTypeTag.NANBOX_CHK <> BlueTypeTag.NANBOX
			Local d:Double = Double Ptr(Varptr(key))[0]
			If d = Abs Int(d) Then numcount[Ceil(Log(d + 1) / Log(2))] :+ 1 Else tsize :+ 1
		Else
			tsize :+ 1
		EndIf
		For Local i:Int = 0 Until 32	'tally up
			If i Then numcount[i] :+ numcount[i - 1]
			If numcount[i] > 2 ^ i / 2 Then asize = 2 ^ i
		Next
		
		If arraypart <> Null	'complete new table size with any discarded array elements
			For Local i:Int = asize Until Int Ptr(arraypart)[-1]
				If Int Ptr(arraypart)[i * 2 + 1] <> NILTAG Then tsize :+ 1
			Next
		EndIf
		
		Local newarray:Byte Ptr = Null, newtable:Byte Ptr = Null	'allocate and copy
		If asize
			newarray = mem.AllocObject(asize * 8 + 8, BlueTypeTag.ARR) + 8
			For Local i:Int = 0 Until asize
				Int Ptr(newarray)[i * 2 + 1] = NILTAG
			Next
			Int Ptr(newarray)[-1] = asize ; Byte Ptr Ptr(tbl)[3] = newarray
		Else
			Int Ptr(tbl)[3] = 0
		EndIf
		If tsize
			tsize = 2 ^ tsize
			newtable = mem.AllocObject(tsize * 16 + 8, BlueTypeTag.HASH)
			For Local i:Int = 0 Until tsize * 2
				Int Ptr(newtable)[i * 2 + 1] = NILTAG
			Next
			Int Ptr(newtable)[-1] = tsize ; Byte Ptr Ptr(tbl)[2] = newtable
		Else
			Int Ptr(tbl)[2] = 0
		EndIf
		
		For Local i:Int = 0 Until Int Ptr(arraypart)[-1]	'reinsert values
			Set Null, tbl, Double(i),�Long Ptr(arraypart)[i]
		Next
		For Local i:Int = 0 Until Int Ptr(hashpart)[-1]
			Set Null, tbl, Long Ptr(hashpart)[i * 2], Long Ptr(hashpart)[i * 2 + 1]	'Null used here as a sentinel (it should not be used again, so...)
		Next
	End Function
End Type
