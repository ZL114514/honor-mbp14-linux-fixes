// SSDT20 (OEM "HONOR", table id "ARL", rev 2) - excerpt, 2026-11-14
// Source: /sys/firmware/acpi/tables/SSDT20, disassembled with iasl -d
// The touch power resource is declared under I2C5, a controller this SKU
// does not have; the real panel is \_SB.PC00.I2C2.TPL1 (FTSC1000).
// Boot log: ACPI BIOS Error (bug): Could not resolve symbol
//           [\_SB.PC00.I2C5.TPL1], AE_NOT_FOUND
// Same template block also exists for I2C3 (.TPD0) and I2C4 (.TPL1).
// Result: PTPL is created but never referenced by a live device, so _ON never
// runs and GPP_A_12 (reset) stays low -> i2c 0x38 NAK.

    Scope (\_SB.PC00.I2C5)
    {
        Name (ONTM, Zero)
        Name (TPPE, Zero)
        Name (TPPR, Zero)
        Name (TPIP, Zero)
        Name (TPEP, Zero)
        Name (TPRP, Zero)
        Name (TPI2, Zero)
        TPPE = T1PE /* External reference */
        TPPR = T1PR /* External reference */
        TPIP = T1IP /* External reference */
        TPEP = T1EP /* External reference */
        TPRP = T1RP /* External reference */
        TPI2 = T1GI /* External reference */
        If ((TPLT != Zero))
        {
            If ((TPLS == One))
            {
                Method (PS0X, 0, Serialized)
                {
                    ADBG (Concatenate ("_PS0 I2C controller= ", ToHexString (I2CI)))
                }

                Method (PS3X, 0, Serialized)
                {
                    ADBG (Concatenate ("_PS3 I2C controller= ", ToHexString (I2CI)))
                }

                If ((TPLT != Zero))
                {
                    PowerResource (PTPL, 0x00, 0x0000)
                    {
                        Method (_STA, 0, NotSerialized)  // _STA: Status
                        {
                            If ((\_SB.GGOV (TPPE) == One))
                            {
                                ADBG (Concatenate ("TPL _STA ON I2C controller= ", ToHexString (I2CI)))
                                Return (One)
                            }
                            Else
                            {
                                ADBG (Concatenate ("TPL _STA OFF I2C controller= ", ToHexString (I2CI)))
                                Return (Zero)
                            }
                        }

                        Method (_ON, 0, NotSerialized)  // _ON_: Power On
                        {
                            ADBG (Concatenate ("Touch PWR ON I2C controller= ", ToHexString (I2CI)))
                            \_SB.SGOV (TPPE, TPEP)
                            Sleep (0x02)
                            \_SB.SGOV (TPPR, TPRP)
                            ONTM = Timer
                            \_SB.SGRA (TPI2, TPIP)
                        }

                        Method (_OFF, 0, NotSerialized)  // _OFF: Power Off
                        {
                            ADBG (Concatenate ("Touch PWR OFF I2C controller= ", ToHexString (I2CI)))
                            Local0 = (TPIP ^ One)
                            \_SB.SGRA (TPI2, Local0)
                            Local0 = (TPRP ^ One)
                            \_SB.SGOV (TPPR, Local0)
                            Sleep (0x03)
                            Local0 = (TPEP ^ One)
                            \_SB.SGOV (TPPE, Local0)
                            ONTM = Zero
                        }
                    }
                }

                Scope (TPL1)
                {
                    Name (TD_P, Package (0x01)
                    {
                        \_SB.PC00.I2C5.PTPL
                    })
                    Alias (\_SB.PC00.I2C5.ONTM, TD_C)
                    Name (TD_N, "TPL1")
                    Alias (IC1D, TD_D)
                    Method (PS0X, 0, Serialized)
                    {
                        ADBG (Concatenate (TD_N, " D0"))
                        If ((TD_C == Zero))
                        {
                            Return (Zero)
                        }

                        Local0 = ((Timer - TD_C) / 0x2710)
                        Local1 = (TD_D + VRRD) /* External reference */
                        If ((Local0 < Local1))
                        {
                            Sleep ((Local1 - Local0))
                        }
                    }

                    Method (PS3X, 0, Serialized)
                    {
                        ADBG (Concatenate (TD_N, " D3"))
                    }

                    Method (_PR0, 0, NotSerialized)  // _PR0: Power Resources for D0
                    {
                        If ((_STA () == 0x0F))
                        {
                            Return (TD_P) /* \_SB_.PC00.I2C5.TPL1.TD_P */
                        }
                        Else
                        {
                            Return (Package (0x00){})
                        }
                    }

                    Method (_PR3, 0, NotSerialized)  // _PR3: Power Resources for D3hot
                    {
                        If ((_STA () == 0x0F))
                        {
                            Return (TD_P) /* \_SB_.PC00.I2C5.TPL1.TD_P */
                        }
                        Else
                        {
                            Return (Package (0x00){})
                        }
                    }

                    Method (_PS0, 0, NotSerialized)  // _PS0: Power State 0
                    {
                        PS0X ()
                    }

                    Method (_PS3, 0, NotSerialized)  // _PS3: Power State 3
                    {
                        PS3X ()
                    }
                }
            }
        }
    }
