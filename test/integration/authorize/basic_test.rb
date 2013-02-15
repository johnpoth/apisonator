require File.expand_path(File.dirname(__FILE__) + '/../../test_helper')

class AuthorizeBasicTest < Test::Unit::TestCase
  include TestHelpers::AuthorizeAssertions
  include TestHelpers::Fixtures
  include TestHelpers::Integration

  def setup
    @storage = Storage.instance(true)
    @storage.flushdb

    Resque.reset!
    Memoizer.reset!

    setup_provider_fixtures

    @application = Application.save(:service_id => @service.id,
                                    :id         => next_id,
                                    :state      => :active,
                                    :plan_id    => @plan_id,
                                    :plan_name  => @plan_name)

    @metric_id = next_id
    Metric.save(:service_id => @service.id, :id => @metric_id, :name => 'hits')
  end

  test 'successful authorize responds with 200' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id

    assert_equal 200, last_response.status
  end

  test 'successful authorize with no body responds with 200' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id,
                                       :no_body      => true

    assert_equal 200, last_response.status
    assert_equal "", last_response.body
  end

  test 'successful authorize has custom content type' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id

    assert_includes last_response.content_type, 'application/vnd.3scale-v2.0+xml'
  end

  test 'successful authorize renders plan name' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id     => @application.id

    doc = Nokogiri::XML(last_response.body)
    assert_equal @plan_name, doc.at('status:root plan').content
  end

  test 'response of successful authorize contains authorized flag set to true' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id     => @application.id

    doc = Nokogiri::XML(last_response.body)
    assert_equal 'true', doc.at('status:root authorized').content
  end

  test 'response of successful authorize contains usage reports if the plan has usage limits' do
    UsageLimit.save(:service_id => @service.id,
                    :plan_id    => @plan_id,
                    :metric_id  => @metric_id,
                    :day => 100, :month => 10000)

    Timecop.freeze(Time.utc(2010, 5, 14)) do
      Transactor.report(@provider_key, @service.id,
                        0 => {'app_id' => @application.id, 'usage' => {'hits' => 3}})
      Resque.run!
    end

    Timecop.freeze(Time.utc(2010, 5, 15)) do
      Transactor.report(@provider_key, @service.id,
                        0 => {'app_id' => @application.id, 'usage' => {'hits' => 2}})
      Resque.run!
    end

    Timecop.freeze(Time.utc(2010, 5, 15)) do
      get '/transactions/authorize.xml', :provider_key => @provider_key,
                                         :app_id     => @application.id

      doc = Nokogiri::XML(last_response.body)

      usage_reports = doc.at('usage_reports')
      assert_not_nil usage_reports

      day = usage_reports.at('usage_report[metric = "hits"][period = "day"]')
      assert_not_nil day
      assert_equal '2010-05-15 00:00:00 +0000', day.at('period_start').content
      assert_equal '2010-05-16 00:00:00 +0000', day.at('period_end').content
      assert_equal '2',                         day.at('current_value').content
      assert_equal '100',                       day.at('max_value').content

      month = usage_reports.at('usage_report[metric = "hits"][period = "month"]')
      assert_not_nil month
      assert_equal '2010-05-01 00:00:00 +0000', month.at('period_start').content
      assert_equal '2010-06-01 00:00:00 +0000', month.at('period_end').content
      assert_equal '5',                         month.at('current_value').content
      assert_equal '10000',                     month.at('max_value').content
    end
  end

  test 'response of successful authorize does not contain usage reports if the plan has no usage limits' do
    Timecop.freeze(Time.utc(2010, 5, 15)) do
      Transactor.report(@provider_key, @service.id,
                        0 => {'app_id' => @application.id, 'usage' => {'hits' => 2}})

      get '/transactions/authorize.xml', :provider_key => @provider_key,
                                         :app_id     => @application.id

      doc = Nokogiri::XML(last_response.body)

      assert_nil doc.at('usage_reports')
    end
  end

  test 'fails on invalid provider key' do
    get '/transactions/authorize.xml', :provider_key => 'boo',
                                       :app_id     => @application.id

    assert_error_response :code    => 'provider_key_invalid',
                          :message => 'provider key "boo" is invalid'
  end

  test 'fails on invalid provider key with no body' do
    get '/transactions/authorize.xml', :provider_key => 'boo',
                                       :app_id     => @application.id,
                                       :no_body    => true

    assert_equal 403, last_response.status
    assert_equal "", last_response.body
  end

  test 'fails on invalid application id' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => 'boo'


    assert_error_response :status  => 404,
                          :code    => 'application_not_found',
                          :message => 'application with id="boo" was not found'
  end

  test 'fails on invalid application id with no body' do
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => 'boo',
                                       :no_body      => true


    assert_equal 404, last_response.status
    assert_equal "", last_response.body
  end

  test 'fails on missing application id' do
    get '/transactions/authorize.xml', :provider_key => @provider_key

    assert_error_response :status  => 404,
                          :code    => 'application_not_found'
  end

  test 'does not authorize on inactive application' do
    @application.state = :suspended
    @application.save

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id

    assert_equal 409, last_response.status
    assert_not_authorized 'application is not active'
  end
  
  test 'does not authorize on inactive application with no body' do
    @application.state = :suspended
    @application.save

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id,
                                       :no_body      => true

    assert_equal 409, last_response.status
    assert_equal "", last_response.body
  end

  test 'does not authorize on exceeded client usage limits' do
    UsageLimit.save(:service_id => @service.id,
                    :plan_id    => @plan_id,
                    :metric_id  => @metric_id,
                    :day => 4)

    Transactor.report(@provider_key, nil,
                      0 => {'app_id' => @application.id, 'usage' => {'hits' => 5}})

    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id     => @application.id

    assert_equal 409, last_response.status
    assert_not_authorized 'usage limits are exceeded'
  end

  test 'does not authorize on exceeded client usage limits with no body' do
    UsageLimit.save(:service_id => @service.id,
                    :plan_id    => @plan_id,
                    :metric_id  => @metric_id,
                    :day => 4)

    Transactor.report(@provider_key, @service.id,
                      0 => {'app_id' => @application.id, 'usage' => {'hits' => 5}})

    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id     => @application.id,
                                       :no_body    => true

    assert_equal 409, last_response.status
    assert_equal "", last_response.body
  end

  test 'response contains usage reports marked as exceeded on exceeded client usage limits' do
    UsageLimit.save(:service_id => @service.id,
                    :plan_id    => @plan_id,
                    :metric_id  => @metric_id,
                    :month => 10, :day => 4)

    Transactor.report(@provider_key, @service.id,
                      0 => {'app_id' => @application.id, 'usage' => {'hits' => 5}})

    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id

    doc   = Nokogiri::XML(last_response.body)
    day   = doc.at('usage_report[metric = "hits"][period = "day"]')
    month = doc.at('usage_report[metric = "hits"][period = "month"]')

    assert_equal 'true', day['exceeded']
    assert_nil           month['exceeded']
  end

  test 'succeeds on exceeded provider usage limits' do
    UsageLimit.save(:service_id => @master_service_id,
                    :plan_id    => @master_plan_id,
                    :metric_id  => @master_hits_id,
                    :day        => 2)

    3.times do
      Transactor.report(@provider_key, @service.id,
                        0 => {'app_id' => @application.id, 'usage' => {'hits' => 1}})
    end

    Resque.run!

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id
    assert_authorized
  end

  test 'succeeds on eternity limits' do

    Timecop.freeze(Time.utc(2010, 5, 15)) do

      UsageLimit.save(:service_id => @service.id,
                      :plan_id    => @plan_id,
                      :metric_id  => @metric_id,
                      :month => 4)
    
      UsageLimit.save(:service_id => @service.id,
                      :plan_id    => @plan_id,
                      :metric_id  => @metric_id,
                      :eternity   => 10)


      3.times do
        Transactor.report(@provider_key, nil,
                          0 => {'app_id' => @application.id, 'usage' => {'hits' => 1}})
      end

      Resque.run!

      get '/transactions/authorize.xml', :provider_key => @provider_key,
                                         :app_id       => @application.id
      
      doc   = Nokogiri::XML(last_response.body)
      month   = doc.at('usage_report[metric = "hits"][period = "month"]')      
      assert_not_nil month
      assert_equal '2010-05-01 00:00:00 +0000', month.at('period_start').content
      assert_equal '2010-06-01 00:00:00 +0000', month.at('period_end').content
      assert_equal '3', month.at('current_value').content
      assert_equal '4', month.at('max_value').content
      assert_nil   month['exceeded']


      eternity   = doc.at('usage_report[metric = "hits"][period = "eternity"]')      
      assert_not_nil  eternity
      assert_nil      eternity.at('period_start')
      assert_nil      eternity.at('period_end')
      assert_equal    '3', eternity.at('current_value').content
      assert_equal    '10', eternity.at('max_value').content
      assert_nil      eternity['exceeded']

    end

   
  end

  test 'does not authorize on eternity limits' do

    Timecop.freeze(Time.utc(2010, 5, 15)) do

      UsageLimit.save(:service_id => @service.id,
                      :plan_id    => @plan_id,
                      :metric_id  => @metric_id,
                      :month => 20)
    
      UsageLimit.save(:service_id => @service.id,
                      :plan_id    => @plan_id,
                      :metric_id  => @metric_id,
                      :eternity   => 2)


      3.times do
        Transactor.report(@provider_key, nil,
                          0 => {'app_id' => @application.id, 'usage' => {'hits' => 1}})
      end

      Resque.run!

      get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id
      
      doc   = Nokogiri::XML(last_response.body)
      month   = doc.at('usage_report[metric = "hits"][period = "month"]')      
      assert_not_nil month
      assert_equal  '2010-05-01 00:00:00 +0000', month.at('period_start').content
      assert_equal  '2010-06-01 00:00:00 +0000', month.at('period_end').content
      assert_equal  '3', month.at('current_value').content
      assert_equal  '20', month.at('max_value').content
      assert_nil    month['exceeded']

      eternity   = doc.at('usage_report[metric = "hits"][period = "eternity"]')      
      assert_not_nil  eternity
      assert_nil      eternity.at('period_start')
      assert_nil      eternity.at('period_end')
      assert_equal    '3', eternity.at('current_value').content
      assert_equal    '2', eternity.at('max_value').content
      assert_equal    'true', eternity['exceeded']


    end

  end

  test 'eternity is not returned if the limit on it is not defined' do

    Timecop.freeze(Time.utc(2010, 5, 15)) do

      UsageLimit.save(:service_id => @service.id,
                      :plan_id    => @plan_id,
                      :metric_id  => @metric_id,
                      :month => 20)

      1.times do
        Transactor.report(@provider_key, nil,
                          0 => {'app_id' => @application.id, 'usage' => {'hits' => 1}})
      end

      Resque.run!

      get '/transactions/authorize.xml', :provider_key => @provider_key,
                                       :app_id       => @application.id
    
      doc   = Nokogiri::XML(last_response.body)
      month   = doc.at('usage_report[metric = "hits"][period = "month"]')
      eternity   = doc.at('usage_report[metric = "hits"][period = "eternity"]')

      assert_not_nil month
      assert_nil     eternity
    
    end
  end

  test 'usage must be an array regression' do

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application.id,
                                     :usage        => ""
    assert_equal 403, last_response.status

    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                     :app_id       => @application.id,
                                     :usage        => "1001"
    assert_equal 403, last_response.status

  end
  
  
  test 'regression test for utf8 issues and super malformed request' do
  
    get '/transactions/authorize.xml', :provider_key => "\xf0\x90\x28\xbc"
                                                                                                                   
    assert_equal 400, last_response.status

    assert_error_response :status  => 400,
                          :code    => 'not_valid_data',
                          :message => 'all data must be valid UTF8'
                          
    
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                        :app_id => "\xf0\x90\x28\xbc"
                                                                       
    assert_equal 400, last_response.status

    assert_error_response :status  => 400,
                          :code    => 'not_valid_data',
                          :message => 'all data must be valid UTF8'
                          
    
    get '/transactions/authorize.xml', :provider_key => @provider_key,
                                        :app_id => @application.id,
                                        :app_key => "\xf0\x90\x28\xbc"
                                                                           
    assert_equal 400, last_response.status

    assert_error_response :status  => 400,
                          :code    => 'not_valid_data',
                          :message => 'all data must be valid UTF8'
                                                        
    get '/transactions/authorize.xml',  :provider_key => @provider_key,
                                        :app_id => @application.id,
                                        :usage => {"\xf0\x90\x28\xbc" => 1}
                                                                           
    assert_equal 400, last_response.status

    get '/transactions/authorize.xml',  :provider_key => @provider_key,
                                        :app_id => @application.id,
                                        :usage => {"\xf0\x90\x28\xbc" => 1}

    ## FIXME: rack test is doing something fishy here. It does not call the rack middleware rack_exception_catcher like
    ## the examples above. Could be for the explicit querystring,
    ## get '/transactions/authorize.xml?provider_key=FAKE&app_id=FAKE&usage%5D%5B%5D=1&%5Busage%5D%5Bkilobytes_out%5D=1'
    ## will simulate the error to get at least some coverage
    
    Transactor.stubs(:authorize).raises(TypeError.new("expected Hash (got Array) for param `usage'"))
    
    assert_nothing_raised do
      
      get '/transactions/authorize.xml',  :provider_key => "FAKE",
                                          :app_id => "FAKE"
                         
      assert_equal 400, last_response.status
                                        
      assert_error_response :status  => 400,
                            :code    => 'bad_request',
                            :message => 'request contains syntanx errors, should not be repeated without modification'
    end                      
                          
  end
    


end
