# Cookbook:: commvault
# Library:: api

require 'uri'
require 'net/http'
require 'mixlib/shellout'
require 'json'
require 'digest'

module CommVault
  module Api
    def cv_token_local
      token = if platform?('windows')
                Mixlib::ShellOut.new('C:\\Progra~1\\Commvault\\ContentStore\\Base\\QLogin.exe -localadmin -gt')
              else
                Mixlib::ShellOut.new('/opt/commvault/Base/qlogin -localadmin -gt')
              end
      token.run_command
      "QSDK #{token.stdout}"
    end

    def cv_token_api(endpoint, user, pass)
      url = URI("#{endpoint}/Login")
      body = %({ \"username\": #{user.dump}, \"password\": #{Base64.strict_encode64(pass).dump}, })
      Chef::Log.debug "Current body: [#{body}]"
      response = _post(url, nil, body)
      raise "Incorrect output received while logging into REST API endpoint #{endpoint}" unless response
      raise "API gave error code [#{response.code}] for our request to login\nResponse: [#{response.message}]" if response.code.to_i != 200
      _extract(response.body(), 'token')
    end

    def cv_client_name
      if platform?('windows')
        registry_get_values('HKLM\SOFTWARE\CommVault Systems\Galaxy\Instance001').select { |x| x[:name].casecmp?('sPhysicalNodeName') }.first[:data]
      else
        File.readlines('/etc/CommVaultRegistry/Galaxy/Instance001/.properties').grep(/sPhysicalNodeName/)[0].chomp.split[1]
      end
    end

    def cv_fs_licensed(endpoint, cv_token)
      clientid = _cv_client_id(endpoint, cv_token)
      url = URI("#{endpoint}/Client/#{clientid}/License")
      data = JSON.parse(_get(url, cv_token).read_body)
      if data && data.key?('licensesInfo')
        data = data['licensesInfo'].select { |x| [33, 29].include?(x['license']['appType'].to_i) }
        return data.length == 1
      end
      false
    end

    def cv_fs_reconfigure(endpoint, cv_token)
      clientid = _cv_client_id(endpoint, cv_token)
      url = URI("#{endpoint}/Client/License/Reconfigure")
      body = "{ \"clientInfo\": { \"clientId\": #{clientid} }, \"platformTypes\": [ 1 ], \"appTypes\": [ { \"applicationId\": 29 } ] }"
      response = _post(url, cv_token, body)
      raise 'Incorrect output received while reconfiguring file system agent' unless response
      raise "API gave error code [#{response.code}] for our request to reconfigure file system agent\nResponse: [#{response.message}]" if response.code.to_i != 200
    end

    # This does not work with the current way we get the token (does not have enough rights), keeping around for potential future use)
    def cv_install_updates(endpoint, cv_token)
      clientid = _cv_client_id(endpoint, cv_token)
      url = URI("#{endpoint}/CreateTask")
      body = "{ \"taskInfo\": { \"task\": { \"taskType\": 1 }, \"subTasks\": [ { \"subTask\": { \"subTaskType\": 1, \"operationType\": 4020 }, \"options\": { \"adminOpts\": { \"updateOption\": { \"ignoreRunningJobs\": true, \"rebootClient\": false, \"clientAndClientGroups\": [ { \"clientSidePackage\": true, \"clientId\": #{clientid}, \"consumeLicense\": true } ], \"clientId\": [ #{clientid} ], \"installUpdatesJobType\": { \"installUpdates\": true } } } } } ] } }"
      _post(url, cv_token, body)
    end

    def cv_fs_filter(endpoint, cv_token, subclient_name, filters)
      unless filters.instance_of?(Array)
        raise 'We expect filters to be of type Array'
      end

      # If the filters are empty we assume no plan override
      if filters.empty?
        # Only reset to plan based if we aren't deriving
        _cv_fs_subclient_set_plan_override(endpoint, cv_token, subclient_name, false, filters) if cv_fs_subclient_is_plan_override(endpoint, cv_token, subclient_name)
      else
        # Always set the filters as they might have changed (we do an override here)
        _cv_fs_subclient_set_plan_override(endpoint, cv_token, subclient_name, true, filters)
      end
    end

    def cv_fs_subclient_is_plan_override(endpoint, cv_token, subclient_name)
      props = _cv_fs_properties(endpoint, cv_token, subclient_name)
      raise 'Received incorrect output from CommVault API' unless props
      props['subClientProperties'][0]['useLocalContent'] == true
    end

    def _cv_fs_subclient_set_plan_override(endpoint, cv_token, subclient_name, status, filters)
      unless subclient_name == 'default'
        raise 'We are unable to manage any subclient other than default for now'
      end
      url = URI("#{endpoint}/Subclient/#{_cv_fs_subclient_id(endpoint, cv_token, subclient_name)}")
      body = ''
      if status
        unless filters.instance_of?(Array)
          raise 'We expect filters to be of type Array'
        end
        tmp = []
        if platform?('windows')
          tmp.push('{ "path": "\\\\" }')
        else
          tmp.push('{ "path": "/" }')
        end
        filters.each do |entry|
          tmp.push(%({ \"excludePath\": #{entry.dump} }))
        end
        body = "{ \"subClientProperties\": { \"fsIncludeFilterOperationType\": 4, \"fsExcludeFilterOperationType\": 1, \"fsContentOperationType\": 1, \"useLocalContent\": true, \"fsSubClientProp\": { \"useGlobalFilters\": 2, \"customSubclientContentFlags\": 0, \"backupSystemState\": true, \"customSubclientFlag\": true, \"openvmsBackupDate\": false, \"includePolicyFilters\": true }, \"content\": [ #{tmp.join(',')} ] } }"
      else
        body = '{ "subClientProperties": { "useLocalContent": false } }'
      end
      Chef::Log.debug "Current body: [#{body}]"
      response = _post(url, cv_token, body)
      raise "Incorrect output received while updating subclient #{subclient_name}" unless response
      raise "API gave error code [#{response.code}] for our request to update the subclient. This most likely means the filters are incorrect. You can run chef with debug log level to see the actual body" if response.code.to_i != 200
    end

    def _cv_client_id(endpoint, cv_token)
      url = URI("#{endpoint}/GetId?clientname=#{cv_client_name}")
      response = _get(url, cv_token)
      raise "Unable to get client id for client name [#{cv_client_name}]" unless response && response.code.to_i == 200
      cid = _extract(response.body(), 'clientId')
      raise "Incorrect client id received from API -> [#{cid}], code: [#{response.code}]" unless cid && cid.match(/^(\d)+$/)
      cid
    end

    def _cv_fs_subclient_id(endpoint, cv_token, subclient_name)
      url = URI("#{endpoint}/GetId?clientname=#{cv_client_name}&agent=File%20System&backupset=defaultBackupSet&subclient=#{subclient_name}")
      _extract(_get(url, cv_token).read_body, 'subclientId')
    end

    def _cv_fs_properties(endpoint, cv_token, subclient_name)
      url = URI("#{endpoint}/Subclient/#{_cv_fs_subclient_id(endpoint, cv_token, subclient_name)}")
      JSON.parse(_get(url, cv_token).read_body)
    end

    def _get(endpoint, token)
      http = Net::HTTP.new(endpoint.host, endpoint.port)
      http.use_ssl = endpoint.scheme == 'https'
      request = Net::HTTP::Get.new(endpoint)
      request['Accept'] = 'application/json'
      request['Authtoken'] = token unless token.nil?
      http.request(request)
    end

    def _post(endpoint, token, body)
      http = Net::HTTP.new(endpoint.host, endpoint.port)
      http.use_ssl = endpoint.scheme == 'https'
      request = Net::HTTP::Post.new(endpoint)
      request['Accept'] = 'application/json'
      request['Authtoken'] = token unless token.nil?
      request['Content-Type'] = 'application/json'
      request.body = body
      http.request(request)
    end

    def _extract(body, variable)
      String(
        JSON.parse(body)[variable]
      )
    rescue
      false
    end
  end
end
