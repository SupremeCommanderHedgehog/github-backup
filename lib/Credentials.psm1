Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Direct P/Invoke against advapi32.dll's Cred* APIs.
# Avoids the PSGallery CredentialManager module, which depends on
# System.Web (unavailable in .NET Core / PowerShell 7) and fails to load
# its cmdlets at runtime.

if (-not ('GhBackup.NativeCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace GhBackup {
    public static class NativeCred {
        public const uint CRED_TYPE_GENERIC        = 1;
        public const uint CRED_PERSIST_LOCAL_MACHINE = 2;
        public const int  ERROR_NOT_FOUND          = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CREDENTIAL {
            public uint   Flags;
            public uint   Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint   CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint   Persist;
            public uint   AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredWriteW")]
        public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredReadW")]
        public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredDeleteW")]
        public static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("advapi32.dll", SetLastError = false)]
        public static extern void CredFree(IntPtr buffer);
    }
}
'@
}

function Set-BackupCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][securestring]$Token
    )

    # SecureString -> UTF-16 bytes
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
        $secretBytes = [System.Text.Encoding]::Unicode.GetBytes($plain)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $cred = New-Object GhBackup.NativeCred+CREDENTIAL
    $cred.Type    = [GhBackup.NativeCred]::CRED_TYPE_GENERIC
    $cred.Persist = [GhBackup.NativeCred]::CRED_PERSIST_LOCAL_MACHINE
    $cred.TargetName        = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($Name)
    $cred.UserName          = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni('token')
    $cred.CredentialBlob    = [Runtime.InteropServices.Marshal]::AllocCoTaskMem($secretBytes.Length)
    $cred.CredentialBlobSize = [uint32]$secretBytes.Length
    [Runtime.InteropServices.Marshal]::Copy($secretBytes, 0, $cred.CredentialBlob, $secretBytes.Length)

    try {
        if (-not [GhBackup.NativeCred]::CredWrite([ref]$cred, 0)) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed for '$Name' (Win32 error $err)"
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($cred.TargetName)
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($cred.UserName)
        # Zero the blob memory before freeing
        for ($i = 0; $i -lt $secretBytes.Length; $i++) {
            [Runtime.InteropServices.Marshal]::WriteByte($cred.CredentialBlob, $i, 0)
        }
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($cred.CredentialBlob)
        # Best-effort scrub of the temp byte array
        if ($secretBytes) {
            for ($i = 0; $i -lt $secretBytes.Length; $i++) { $secretBytes[$i] = 0 }
        }
    }
}

function Get-BackupCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    [IntPtr]$ptr = [IntPtr]::Zero
    if (-not [GhBackup.NativeCred]::CredRead($Name, [GhBackup.NativeCred]::CRED_TYPE_GENERIC, 0, [ref]$ptr)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -eq [GhBackup.NativeCred]::ERROR_NOT_FOUND) {
            throw "No stored credential named '$Name'. Run Register-Setup.ps1 to store it."
        }
        throw "CredRead failed for '$Name' (Win32 error $err)"
    }
    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][GhBackup.NativeCred+CREDENTIAL])
        $size = [int]$cred.CredentialBlobSize
        if ($size -le 0) { return '' }
        $bytes = New-Object byte[] $size
        [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $size)
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    } finally {
        [GhBackup.NativeCred]::CredFree($ptr)
    }
}

function Test-BackupCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    [IntPtr]$ptr = [IntPtr]::Zero
    $found = [GhBackup.NativeCred]::CredRead($Name, [GhBackup.NativeCred]::CRED_TYPE_GENERIC, 0, [ref]$ptr)
    if ($found) {
        [GhBackup.NativeCred]::CredFree($ptr)
        return $true
    }
    return $false
}

function Remove-BackupCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (-not [GhBackup.NativeCred]::CredDelete($Name, [GhBackup.NativeCred]::CRED_TYPE_GENERIC, 0)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -ne [GhBackup.NativeCred]::ERROR_NOT_FOUND) {
            throw "CredDelete failed for '$Name' (Win32 error $err)"
        }
    }
}

Export-ModuleMember -Function Set-BackupCredential, Get-BackupCredential, Test-BackupCredential, Remove-BackupCredential
