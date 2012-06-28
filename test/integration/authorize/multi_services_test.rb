require File.expand_path(File.dirname(__FILE__) + '/../../test_helper')

class MultiServicesTest < Test::Unit::TestCase
  include TestHelpers::AuthorizeAssertions
  include TestHelpers::Fixtures
  include TestHelpers::Integration
  include TestHelpers::StorageKeys
  include TestHelpers::Errors


  def setup
    @storage = Storage.instance(true)
    @storage.flushdb

    Resque.reset!

    setup_provider_fixtures_multiple_services

    @application_1 = Application.save(:service_id => @service_1.id,
                                    :id         => next_id,
                                    :state      => :active,
                                    :plan_id    => @plan_id_1,
                                    :plan_name  => @plan_name_1)

    @application_2 = Application.save(:service_id => @service_2.id,
                                    :id         => next_id,
                                    :state      => :active,
                                    :plan_id    => @plan_id_2,
                                    :plan_name  => @plan_name_2)

    @application_3 = Application.save(:service_id => @service_3.id,
                                    :id         => next_id,
                                    :state      => :active,
                                    :plan_id    => @plan_id_3,
                                    :plan_name  => @plan_name_3)


    @metric_id_1 = next_id
    Metric.save(:service_id => @service_1.id, :id => @metric_id_1, :name => 'hits')

    @metric_id_2 = next_id
    Metric.save(:service_id => @service_2.id, :id => @metric_id_2, :name => 'hits')

    @metric_id_3 = next_id
    Metric.save(:service_id => @service_3.id, :id => @metric_id_3, :name => 'hits')

    UsageLimit.save(:service_id => @service_1.id,
                    :plan_id    => @plan_id_1,
                    :metric_id  => @metric_id_1,
                    :day => 100)

    UsageLimit.save(:service_id => @service_2.id,
                    :plan_id    => @plan_id_2,
                    :metric_id  => @metric_id_2,
                    :day => 100)

    UsageLimit.save(:service_id => @service_3.id,
                    :plan_id    => @plan_id_3,
                    :metric_id  => @metric_id_3,
                    :day => 100)

  end

  test 'right place to declare service_id' do 

    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id   => @service_3.id,  
      :transactions => {0 => {:service_id => @service_2.id, :app_id => @application_3.id, :usage => {'hits' => 3}}}
    assert_equal 202, last_response.status
    Resque.run!

   
   
    assert_equal 3, @storage.get(application_key(@service_3.id,
                                                 @application_3.id,
                                                 @metric_id_3,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i

    assert_equal 0, @storage.get(application_key(@service_2.id,
                                                 @application_3.id,
                                                 @metric_id_3,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i

    assert_equal 0, @storage.get(application_key(@service_2.id,
                                                 @application_3.id,
                                                 @metric_id_2,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i

    assert_not_errors_in_transactions

  end

  test 'sending an application that does not belong to the default service' do 

    post '/transactions.xml',
      :provider_key => @provider_key,
      :transactions => {0 => {:service_id => @service_3.id, :app_id => @application_3.id, :usage => {'hits' => 3}}}
    assert_equal 202, last_response.status
    Resque.run!

    assert_equal 0, @storage.get(application_key(@service_3.id,
                                                 @application_3.id,
                                                 @metric_id_3,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i


    get "/transactions/errors.xml", :provider_key => @provider_key
    assert_equal 200, last_response.status

    doc = Nokogiri::XML(last_response.body)
    node = doc.search('errors error').first

    assert_not_nil node
    assert_equal 'application_not_found',   node['code']
    assert_equal "application with id=\"#{@application_3.id}\" was not found", node.content

  end

  test 'authorize with fake service_id and app_id' do

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => "fake id",
                                       :service_id   => @service_3.id
    Resque.run!
    assert_equal 404, last_response.status

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_3.id,
                                       :service_id   => "fake id"
    Resque.run!
    assert_equal 403, last_response.status

    assert_not_errors_in_transactions


  end

  test 'check scoping of the applications by service' do 

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_1.id,
                                       :service_id   => @service_3.id
    Resque.run!
    assert_equal 404, last_response.status

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_3.id,
                                       :service_id   => @service_1.id
    Resque.run!
    assert_equal 404, last_response.status
   
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_3.id
    Resque.run!
    assert_equal 404, last_response.status

    assert_not_errors_in_transactions


  end  

  test 'provider key with multiple services with authorize/report works with explicit/implicit service ids' do

   
    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id   => @service_3.id,  
      :transactions => {0 => {:app_id => @application_3.id, :usage => {'hits' => 3}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_3.id,
                                       :service_id   => @service_3.id

    assert_equal 200, last_response.status
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '3', day.at('current_value').content

    assert_equal 3, @storage.get(application_key(@service_3.id,
                                                 @application_3.id,
                                                 @metric_id_3,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i


    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id   => @service_2.id,  
      :transactions => {0 => {:app_id => @application_2.id, :usage => {'hits' => 2}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application_2.id,
                                     :service_id   => @service_2.id,
                                     :usage        => {'hits' => 2}

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '2', day.at('current_value').content

    assert_equal 2, @storage.get(application_key(@service_2.id,
                                                 @application_2.id,
                                                 @metric_id_2,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i

    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id   => @service_1.id,  
      :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 1}}}
    assert_equal 202, last_response.status
    Resque.run!


    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application_1.id,
                                     :service_id   => @service_1.id

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '1', day.at('current_value').content

    assert_equal 1, @storage.get(application_key(@service_1.id,
                                                 @application_1.id,
                                                 @metric_id_1,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i    
    

    ## now without explicit service_id

    post '/transactions.xml',
      :provider_key => @provider_key,
      :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 10}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_1.id

    assert_equal 200, last_response.status
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '11', day.at('current_value').content

    assert_equal 11, @storage.get(application_key(@service_1.id,
                                                  @application_1.id,
                                                  @metric_id_1,
                                                  :month, Time.now.strftime("%Y%m01"))).to_i   


    assert_not_errors_in_transactions

  
  end

  test 'provider key with multiple services, check that call to authorize works with explicit/implicit service ids while changing the default service' do

    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id   => @service_2.id,  
      :transactions => {0 => {:app_id => @application_2.id, :usage => {'hits' => 2}}}
    assert_equal 202, last_response.status
    Resque.run!


    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_2.id,
                                       :service_id   => @service_2.id

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '2', day.at('current_value').content

    assert_equal 2, @storage.get(application_key(@service_2.id,
                                                 @application_2.id,
                                                 @metric_id_2,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i

    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id   => @service_1.id,  
      :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 1}}}
    assert_equal 202, last_response.status
    Resque.run!


    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_1.id,
                                       :service_id   => @service_1.id

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '1', day.at('current_value').content

    assert_equal 1, @storage.get(application_key(@service_1.id,
                                                 @application_1.id,
                                                 @metric_id_1,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i    
    
    ## now without explicit service_id
    post '/transactions.xml',
      :provider_key => @provider_key,
      :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 10}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_1.id,
                                       :usage        => {'hits' => 10}

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '11', day.at('current_value').content

    assert_equal 11, @storage.get(application_key(@service_1.id,
                                                  @application_1.id,
                                                  @metric_id_1,
                                                  :month, Time.now.strftime("%Y%m01"))).to_i   

    ## now, change the default service id to be the second one

    @service_2.make_default_service

    post '/transactions.xml',
      :provider_key => @provider_key,
      :transactions => {0 => {:app_id => @application_2.id, :usage => {'hits' => 10}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application_2.id,
                                     :usage        => {'hits' => 10}

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '12', day.at('current_value').content

    assert_equal 12, @storage.get(application_key(@service_2.id,
                                                  @application_2.id,
                                                  @metric_id_2,
                                                  :month, Time.now.strftime("%Y%m01"))).to_i   
    
    assert_equal 11, @storage.get(application_key(@service_1.id,
                                                  @application_1.id,
                                                  @metric_id_1,
                                                  :month, Time.now.strftime("%Y%m01"))).to_i
    

    ## more calls
    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id => @service_1.id,
      :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 20}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application_1.id,
                                     :service_id   => @service_1.id

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '31', day.at('current_value').content

    assert_equal 31, @storage.get(application_key(@service_1.id,
                                                 @application_1.id,
                                                 @metric_id_1,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i    

    post '/transactions.xml',
      :provider_key => @provider_key,
      :service_id => @service_2.id,
      :transactions => {0 => {:app_id => @application_2.id, :usage => {'hits' => 20}}}
    assert_equal 202, last_response.status
    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application_2.id,
                                     :service_id   => @service_2.id,
                                     :usage        => {'hits' => 20}

    assert_equal 200, last_response.status    
    doc = Nokogiri::XML(last_response.body)
    usage_reports = doc.at('usage_reports')
    assert_not_nil usage_reports
    day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
    assert_not_nil day
    assert_equal '32', day.at('current_value').content

    assert_equal 32, @storage.get(application_key(@service_2.id,
                                                 @application_2.id,
                                                 @metric_id_2,
                                                 :month, Time.now.strftime("%Y%m01"))).to_i    

    assert_not_errors_in_transactions

  end

  test 'provider_key needs to be checked regardless if the service_id is correct with authorize/report' do

    get '/transactions/authorize.xml', :provider_key => 'fakeproviderkey',
                                       :app_id       => @application_1.id,
                                       :usage        => {'hits' => 2}

    Resque.run!
    assert_equal 403, last_response.status

    doc = Nokogiri::XML(last_response.body)
    error = doc.at('error:root')
    assert_not_nil error
    assert_equal 'provider_key_invalid', error['code']


    get '/transactions/authorize.xml', :provider_key => 'fakeproviderkey',
                                       :service_id   => @service_1.id,
                                       :app_id       => @application_1.id,
                                       :usage        => {'hits' => 1}
    Resque.run!
    assert_equal 403, last_response.status
    doc = Nokogiri::XML(last_response.body)
    error = doc.at('error:root')
    assert_not_nil error
    assert_equal 'provider_key_invalid', error['code']
   

    get '/transactions/authorize.xml', :provider_key => 'fakeproviderkey',
                                       :service_id   => @service_2.id,
                                       :app_id       => @application_2.id,
                                       :usage        => {'hits' => 2}

    Resque.run!
    assert_equal 403, last_response.status
    doc = Nokogiri::XML(last_response.body)
    error = doc.at('error:root')
    assert_not_nil error
    assert_equal 'provider_key_invalid', error['code']

    assert_not_errors_in_transactions
  
  end

  test 'testing that the app_id matches the service that is default service with authorize' do
  
    ## user want to access the service_2 but forget to add service_id, and app_id == @application_2.id does not
    ## exists for the service_1

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application_2.id,
                                       :usage        => {'hits' => 2}

    Resque.run!
    assert_equal 404, last_response.status
    doc = Nokogiri::XML(last_response.body)
    error = doc.at('error:root')
    assert_not_nil error
    assert_equal 'application_not_found', error['code']
    
    assert_not_errors_in_transactions

  end


  test 'when service_id is not valid there is an error no matter if the provider key is valid with authorize' do

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :service_id   => @service_2.id << "666",
                                     :app_id       => @application_2.id,
                                     :usage        => {'hits' => 2}
    Resque.run!
    assert_equal 403, last_response.status
    doc = Nokogiri::XML(last_response.body)
    error = doc.at('error:root')
    assert_not_nil error
    assert_equal 'service_id_invalid', error['code']

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :service_id   => @service_1.id << "666",
                                       :app_id       => @application_1.id,
                                       :usage        => {'hits' => 2}
    Resque.run!
    assert_equal 403, last_response.status
    doc = Nokogiri::XML(last_response.body)
    error = doc.at('error:root')
    assert_not_nil error
    assert_equal 'service_id_invalid', error['code']

    assert_not_errors_in_transactions


  end

  test 'failed report on invalid provider_key and service_id' do
    Timecop.freeze(Time.utc(2010, 5, 12, 13, 33)) do
      
      post '/transactions.xml',
        :provider_key => @provider_key,
        :service_id => @service_1.id,
        :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 1}}}

      Resque.run!
      assert_equal 202, last_response.status
      
      post '/transactions.xml',
        :provider_key => @provider_key,
        :service_id => "fake_service_id",
        :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 1}}}

      Resque.run!

      assert_equal 403, last_response.status
      doc = Nokogiri::XML(last_response.body)
      error = doc.at('error:root')
      assert_not_nil error
      assert_equal 'provider_key_invalid', error['code']

      post '/transactions.xml',
        :provider_key => "fake_provider_key",
        :service_id => @service_1.id,
        :transactions => {0 => {:app_id => @application_1.id, :usage => {'hits' => 1}}}

      Resque.run!

      assert_equal 403, last_response.status
      doc = Nokogiri::XML(last_response.body)
      error = doc.at('error:root')
      assert_not_nil error
      assert_equal 'provider_key_invalid', error['code']

                  
    end
  
  end

end

