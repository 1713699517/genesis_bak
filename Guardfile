group :backend do
  guard 'shell' do
    watch(/(.*)\.erl/) do |m|
      if system('cd genesis_console && ./rebar compile && ./rebar boss c=test_eunit')
        Notifier.notify("SUCCESS", :title => "Genesis Console")
      else
        Notifier.notify("ERROR", :title => "Genesis Console", :image => :failed)
      end
    end
  end
end

group :console do
  guard 'haml', :input => 'genesis_console/src/assets', :output => 'genesis_console/src/view' do
    watch %r{^genesis_console/src/assets/(.+\.html\.haml)$}
  end

  guard 'sass', :output => 'genesis_console/priv/static/' do
    watch %r{^genesis_console/src/assets/(.+\.s[ac]ss)$}
  end

  guard 'livereload' do
    watch(%r{genesis_console/priv/static/.+\.(js|css)$})
    watch(%r{genesis_console/src/view/.+\.html$})
  end

  guard 'coffeescript', :output => 'genesis_console/priv/static/', :bare => true, :hide_success => true do
    watch(%r{^genesis_console/src/assets/(.+\.coffee)$})
  end
end

group :client do
  guard 'haml', :input => 'client/src', :output => 'client' do
    watch %r{^client/src/(.+\.html\.haml)$}
  end

  guard 'sass', :output => 'client/css/' do
    watch %r{^client/src/(.+\.s[ac]ss)$}
  end

  guard 'coffeescript', :output => 'client/js/', :bare => true, :hide_success => true do
    watch(%r{^client/src/coffee/(.+\.coffee)$})
  end

  guard 'livereload' do
    watch(%r{client/.+\.(js|css)$})
    watch(%r{client/.+\.html$})
  end
end

