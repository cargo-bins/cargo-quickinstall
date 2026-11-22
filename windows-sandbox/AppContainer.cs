// Starts a process in an AppContainer, inside a job object that kills
// everything the process started once it is disposed. windows-sandbox/build.ps1
// and run.ps1 load this with Add-Type.
//
// An AppContainer process runs at Low integrity, and on top of that every
// access check also needs the AppContainer's SID, or ALL APPLICATION
// PACKAGES, to be granted on the object: reads too, not only writes. Without
// the internetClient capability it has no network.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class QuickinstallAppContainer
{
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_NO_WINDOW = 0x08000000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES = (IntPtr)0x00020009;
    const uint SE_GROUP_ENABLED = 0x00000004;
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const int HRESULT_ALREADY_EXISTS = unchecked((int)0x800700B7);

    [StructLayout(LayoutKind.Sequential)]
    struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_CAPABILITIES
    {
        public IntPtr AppContainerSid;
        public IntPtr Capabilities;
        public uint CapabilityCount;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    static extern int CreateAppContainerProfile(string name, string displayName, string description,
        IntPtr capabilities, uint capabilityCount, out IntPtr sid);

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    static extern int DeleteAppContainerProfile(string name);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSidToSid(string sid, out IntPtr psid);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertSidToStringSid(IntPtr psid, out IntPtr sid);

    [DllImport("advapi32.dll")]
    static extern IntPtr FreeSid(IntPtr sid);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value,
        IntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string applicationName, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
        string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    static Win32Exception Fail(string what)
    {
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(code, what + ": " + new Win32Exception(code).Message);
    }

    static string SidToString(IntPtr sid)
    {
        IntPtr str;
        if (!ConvertSidToStringSid(sid, out str)) throw new Win32Exception();
        try { return Marshal.PtrToStringUni(str); } finally { LocalFree(str); }
    }

    // Creates the AppContainer profile, or finds the one that exists, and
    // returns its SID as a string, for icacls.
    public static string Create(string name)
    {
        IntPtr sid;
        int hr = CreateAppContainerProfile(name, name, name, IntPtr.Zero, 0, out sid);
        if (hr == HRESULT_ALREADY_EXISTS)
        {
            hr = DeriveAppContainerSidFromAppContainerName(name, out sid);
        }
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try { return SidToString(sid); } finally { FreeSid(sid); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr securityAttributes,
        uint disposition, uint flags, IntPtr template);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint GetSecurityInfo(IntPtr handle, int objectType, uint securityInfo, IntPtr owner,
        IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint SetSecurityInfo(IntPtr handle, int objectType, uint securityInfo, IntPtr owner,
        IntPtr group, IntPtr dacl, IntPtr sacl);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(IntPtr securityDescriptor,
        uint revision, uint securityInfo, out IntPtr str, out uint length);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string str, uint revision,
        out IntPtr securityDescriptor, out uint length);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetSecurityDescriptorDacl(IntPtr securityDescriptor, out bool present, out IntPtr dacl,
        out bool defaulted);

    const int SE_KERNEL_OBJECT = 6;
    const uint DACL_SECURITY_INFORMATION = 4;
    const uint READ_CONTROL = 0x00020000, WRITE_DAC = 0x00040000;
    const uint OPEN_EXISTING = 3;

    // Returns the DACL of the device behind path (such as \\.\NUL) as SDDL,
    // after adding ace to it when ace is not null and not there yet. Devices
    // grant nothing to AppContainers, and the change lasts until reboot.
    public static string DeviceDacl(string path, string ace)
    {
        IntPtr h = CreateFileW(path, READ_CONTROL | (ace != null ? WRITE_DAC : 0), 7, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == (IntPtr)(-1)) throw Fail("CreateFile " + path);
        try
        {
            IntPtr sd;
            uint err = GetSecurityInfo(h, SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero,
                IntPtr.Zero, IntPtr.Zero, out sd);
            if (err != 0) throw new Win32Exception((int)err, "GetSecurityInfo");
            IntPtr str; uint len;
            try
            {
                if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, 1, DACL_SECURITY_INFORMATION, out str, out len))
                    throw Fail("ConvertSecurityDescriptorToStringSecurityDescriptor");
            }
            finally { LocalFree(sd); }
            string sddl;
            try { sddl = Marshal.PtrToStringUni(str); } finally { LocalFree(str); }
            if (ace == null || sddl.Contains(ace)) return sddl;

            string updated = sddl + ace;
            IntPtr newSd; uint newLen;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(updated, 1, out newSd, out newLen))
                throw Fail("ConvertStringSecurityDescriptorToSecurityDescriptor");
            try
            {
                bool present, defaulted; IntPtr dacl;
                if (!GetSecurityDescriptorDacl(newSd, out present, out dacl, out defaulted)) throw Fail("GetSecurityDescriptorDacl");
                err = SetSecurityInfo(h, SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
                if (err != 0) throw new Win32Exception((int)err, "SetSecurityInfo");
            }
            finally { LocalFree(newSd); }
            return updated;
        }
        finally { CloseHandle(h); }
    }

    // The SID of the AppContainer with that name, which depends on the name
    // only, whichever user asks.
    public static string Sid(string name)
    {
        IntPtr sid;
        int hr = DeriveAppContainerSidFromAppContainerName(name, out sid);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try { return SidToString(sid); } finally { FreeSid(sid); }
    }

    public static void Delete(string name)
    {
        DeleteAppContainerProfile(name);
    }

    // A process in the AppContainer. Disposing it kills it and everything it
    // started, as they all are in its job object.
    public sealed class Process : IDisposable
    {
        IntPtr job, process;
        internal Process(IntPtr job, IntPtr process) { this.job = job; this.process = process; }

        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(process, (uint)milliseconds) == 0;
        }

        public uint ExitCode
        {
            get
            {
                uint code;
                if (!GetExitCodeProcess(process, out code)) throw new Win32Exception();
                return code;
            }
        }

        public void Dispose()
        {
            // Closing the last handle to the job kills everything in it.
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
        }
    }

    // Starts commandLine in the AppContainer with the given capability SIDs
    // (for example S-1-15-3-1, internetClient), current directory and
    // environment, in a new job object.
    public static Process Start(string name, string[] capabilities, string commandLine,
        string currentDirectory, IDictionary<string, string> environment)
    {
        if (capabilities == null) capabilities = new string[0];
        IntPtr containerSid;
        int hr = DeriveAppContainerSidFromAppContainerName(name, out containerSid);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);

        var capSids = new List<IntPtr>();
        IntPtr caps = IntPtr.Zero, secCaps = IntPtr.Zero, attrList = IntPtr.Zero, env = IntPtr.Zero;
        IntPtr job = IntPtr.Zero;
        var pi = new PROCESS_INFORMATION();
        bool started = false;
        try
        {
            int sidAttrSize = Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));
            if (capabilities.Length > 0)
            {
                caps = Marshal.AllocHGlobal(sidAttrSize * capabilities.Length);
                for (int i = 0; i < capabilities.Length; i++)
                {
                    IntPtr capSid;
                    if (!ConvertStringSidToSid(capabilities[i], out capSid)) throw new Win32Exception();
                    capSids.Add(capSid);
                    var sa = new SID_AND_ATTRIBUTES { Sid = capSid, Attributes = SE_GROUP_ENABLED };
                    Marshal.StructureToPtr(sa, caps + i * sidAttrSize, false);
                }
            }

            var sc = new SECURITY_CAPABILITIES
            {
                AppContainerSid = containerSid,
                Capabilities = caps,
                CapabilityCount = (uint)capabilities.Length,
            };
            secCaps = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SECURITY_CAPABILITIES)));
            Marshal.StructureToPtr(sc, secCaps, false);

            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attrList = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref size)) throw Fail("InitializeProcThreadAttributeList");
            if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, secCaps,
                    (IntPtr)Marshal.SizeOf(typeof(SECURITY_CAPABILITIES)), IntPtr.Zero, IntPtr.Zero))
                throw Fail("UpdateProcThreadAttribute");

            var block = new StringBuilder();
            foreach (var kv in environment) block.Append(kv.Key).Append('=').Append(kv.Value).Append('\0');
            block.Append('\0');
            env = Marshal.StringToHGlobalUni(block.ToString());

            var si = new STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.lpAttributeList = attrList;

            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw Fail("CreateJobObject");
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref limits,
                    Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
                throw Fail("SetInformationJobObject");

            // Suspended, so that it is in the job before it can start anything.
            if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW,
                    env, currentDirectory, ref si, out pi))
                throw Fail("CreateProcess");
            if (!AssignProcessToJobObject(job, pi.hProcess))
            {
                var e = Fail("AssignProcessToJobObject");
                TerminateProcess(pi.hProcess, 1);
                throw e;
            }
            if (ResumeThread(pi.hThread) == 0xFFFFFFFF) throw Fail("ResumeThread");
            started = true;
            return new Process(job, pi.hProcess);
        }
        finally
        {
            if (!started)
            {
                if (job != IntPtr.Zero) CloseHandle(job);
                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            }
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (attrList != IntPtr.Zero) { DeleteProcThreadAttributeList(attrList); Marshal.FreeHGlobal(attrList); }
            if (secCaps != IntPtr.Zero) Marshal.FreeHGlobal(secCaps);
            if (caps != IntPtr.Zero) Marshal.FreeHGlobal(caps);
            foreach (var s in capSids) LocalFree(s);
            if (env != IntPtr.Zero) Marshal.FreeHGlobal(env);
            FreeSid(containerSid);
        }
    }
}
