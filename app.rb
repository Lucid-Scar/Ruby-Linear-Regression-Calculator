require 'json'
require 'sinatra'
require 'csv'
require 'roo'
require 'fileutils'

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567)

NUMBER_PATTERN = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/
FileUtils.mkdir_p('uploads')
FileUtils.mkdir_p('public') 

# Safety nets
get('/upload')  { redirect '/' }
get('/process') { redirect '/' }
get('/manual')  { redirect '/' }

get '/' do
  @step = 1
  @points = []
  @metrics = nil
  @error = nil
  erb :index
end

# Upload File
post '/upload' do
  begin
    raise ArgumentError, 'Please select a file to upload.' unless params['dataset'] && params['dataset'][:tempfile]
    
    tempfile = params['dataset'][:tempfile]
    @filename = "#{Time.now.to_i}_#{params['dataset'][:filename]}"
    filepath = File.join('uploads', @filename)
    File.open(filepath, 'wb') { |f| f.write(tempfile.read) }

    raw_data = @filename.end_with?('.csv') ? CSV.read(filepath) : Roo::Spreadsheet.open(filepath).sheet(0).to_a
    raise ArgumentError, 'The uploaded file is empty.' if raw_data.empty?
    
    @headers = raw_data.first.map(&:to_s).map(&:strip)
    if @headers.compact.empty? || NUMBER_PATTERN.match?(@headers[0])
      raise ArgumentError, 'The dataset must contain text headers in the first row.'
    end

    @step = 2 
    @points = []
    erb :index
  rescue => e
    @error = e.message
    @step = 1
    @points = []
    erb :index
  end
end

# Simple Linear Regression
post '/process' do
  begin
    filepath = File.join('uploads', params['filename'])
    raise ArgumentError, 'File lost. Please upload again.' unless File.exist?(filepath)

    raw_data = params['filename'].end_with?('.csv') ? CSV.read(filepath) : Roo::Spreadsheet.open(filepath).sheet(0).to_a
    @headers = raw_data.first.map(&:to_s).map(&:strip)
    
    x_index = params['x_column'].to_i
    y_index = params['y_column'].to_i
    row_limit = params['row_limit'] # Can be 'all', '100', '500', '1000'

    raise ArgumentError, 'Please select two different variables.' if x_index == y_index

    @x_name = @headers[x_index]
    @y_name = @headers[y_index]
    @filename = params['filename'] 

    cleaned_data, x_values, y_values = [], [], []

    raw_data[1..-1].each do |row|
      x_raw, y_raw = row[x_index], row[y_index]
      next if (x_raw.nil? || x_raw.to_s.strip.empty?) && (y_raw.nil? || y_raw.to_s.strip.empty?)

      if valid_number?(x_raw) && valid_number?(y_raw)
        cleaned_data << [x_raw.to_f, y_raw.to_f]
      end
    end

    raise ArgumentError, 'Not enough valid numeric data pairs found in those columns.' if cleaned_data.length < 2

    # Save the FULL cleaned dataset 
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    @clean_filename = "Cleaned_Regression_Data_#{timestamp}.csv"
    
    CSV.open("public/#{@clean_filename}", "w") do |csv|
      csv << [@x_name, @y_name]
      cleaned_data.each { |row| csv << row }
    end

    # row sample limit 
    processed_data = if row_limit == 'all' || row_limit.nil?
                       cleaned_data
                     else
                       cleaned_data.take(row_limit.to_i)
                     end

    x_values = processed_data.map { |p| p[0] }
    y_values = processed_data.map { |p| p[1] }

    @points = x_values.zip(y_values)
    @metrics = calculate_regression(@points)
    
    @step = 3
    erb :index
  rescue => e
    @error = e.message
    @step = 1
    @points = []
    erb :index
  end
end

# Manual Entry
post '/manual' do
  begin
    x_values = parse_values(params['x_values'])
    y_values = parse_values(params['y_values'])
    
    raise ArgumentError, 'Enter at least two complete X/Y pairs.' if x_values.length < 2
    raise ArgumentError, 'X and Y must contain the same number of values.' unless x_values.length == y_values.length

    @x_name = "Manual X Input"
    @y_name = "Manual Y Input"
    
    @points = x_values.zip(y_values)
    @metrics = calculate_regression(@points)
    
    @step = 3
    erb :index
  rescue => e
    @error = e.message
    @step = 1
    @points = Array(params['x_values']).zip(Array(params['y_values']))
    erb :index
  end
end

def valid_number?(val)
  !val.nil? && NUMBER_PATTERN.match?(val.to_s.strip)
end

def parse_values(raw_values)
  values = Array(raw_values).map(&:to_s).map(&:strip)
  raise ArgumentError, 'Only integers or decimal numbers allowed.' if values.empty? || values.any? { |v| v.empty? || !NUMBER_PATTERN.match?(v) }
  values.map(&:to_f)
end

def calculate_regression(points)
  count = points.length
  x_mean = points.sum { |x, _y| x } / count.to_f
  y_mean = points.sum { |_x, y| y } / count.to_f

  sum_x_deviation_squared = points.sum { |x, _y| (x - x_mean)**2 }
  raise ArgumentError, 'The X values must not all be identical.' if sum_x_deviation_squared.zero?

  covariance = points.sum { |x, y| (x - x_mean) * (y - y_mean) }
  sum_y_deviation_squared = points.sum { |_x, y| (y - y_mean)**2 }
  slope = covariance / sum_x_deviation_squared
  intercept = y_mean - slope * x_mean
  
  correlation = sum_y_deviation_squared.zero? ? 0.0 : covariance / Math.sqrt(sum_x_deviation_squared * sum_y_deviation_squared)
  predictions = points.map { |x, _y| intercept + slope * x }
  sse = points.zip(predictions).sum { |(_x, y), prediction| (y - prediction)**2 }

  { slope: slope, intercept: intercept, correlation: correlation, r_squared: correlation**2, sse: sse }
end

helpers do
  def format_number(value)
    format('%.6f', value).sub(/0+\z/, '').sub(/\.\z/, '')
  end
end

__END__
@@index
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Neon Regression Lab</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    :root {
      --ink: #1c2733; --muted: #5d6b79; --steel: #1c6da8;
      --steel-light: #5ba7d8; --orange: #d66a2c;
      --panel: rgba(248, 250, 252, 0.94);
      --line: rgba(54, 75, 94, .25);
    }
    * { box-sizing: border-box; }
    body {
      color: var(--ink); background-color: #dfe5eb;
      background-image: linear-gradient(rgba(44, 67, 87, .11) 1px, transparent 1px),
        linear-gradient(90deg, rgba(44, 67, 87, .11) 1px, transparent 1px);
      background-size: 30px 30px; font-family: "Rajdhani", "Trebuchet MS", sans-serif;
      letter-spacing: .03em;
    }
    .panel {
      background: var(--panel); border: 1px solid rgba(255, 255, 255, .95);
      box-shadow: 0 12px 28px rgba(54, 75, 94, .16), inset 0 1px 0 #fff; border-radius: 4px;
    }
    .metal-title { color: #24394b; text-shadow: 0 2px 0 #fff, 0 0 18px rgba(91, 167, 216, .45); }
    .value { color: var(--steel); text-shadow: 0 1px 0 #fff; }
    .metal-button {
      background: linear-gradient(135deg, #277db4, #164d78); border: 1px solid #a9d8f2;
      box-shadow: 0 4px 12px rgba(28, 109, 168, .28), inset 0 1px 0 rgba(255,255,255,.55); color: #fff;
    }
    input, select { color: #1c4f73; background: #f7f9fb; border: 1px solid #aab8c5; outline: none; }
    input:focus, select:focus { border-color: var(--steel); box-shadow: 0 0 0 3px rgba(91, 167, 216, .22); }
    .metric { border-left: 3px solid var(--orange); }
    .muted { color: var(--muted); }
    .metal-heading { color: #29445b; }
    .metal-status { color: var(--orange); }
    .metal-outline { border-color: #6d9fbe; color: #1c6da8; }
    .metal-alert { border-color: #d66a2c; background: #fff1e9; color: #8a3f1d; box-shadow: 0 5px 15px rgba(214, 106, 44, .15); }
    .metal-alert strong { color: #b14e20; }
    
    .modal-overlay {
      position: fixed; top: 0; left: 0; width: 100%; height: 100%;
      background: rgba(28, 39, 51, 0.8); backdrop-filter: blur(4px);
      display: flex; justify-content: center; align-items: center; z-index: 50;
    }
  </style>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@400;500;600;700&display=swap" rel="stylesheet">
</head>
<body class="min-h-screen relative">
  <main class="mx-auto max-w-6xl px-4 py-8 sm:px-8 sm:py-12">
    <header class="mb-8 border-b border-cyan-400/30 pb-6">
      <h1 class="metal-title text-3xl font-bold uppercase tracking-widest sm:text-5xl">Regression Lab</h1>
      <p class="muted mt-3 max-w-2xl text-sm">Automated Simple Linear Regression with contextual data preprocessing.</p>
    </header>

    <% if @error %>
      <div class="metal-alert mb-6 border p-4 text-sm" role="alert">
        <span class="font-bold">INPUT ERROR:</span> <%= @error %>
      </div>
    <% end %>

    <!-- STEP 2 MODAL POPUP WITH ROW LIMIT OPTION -->
    <% if @step == 2 %>
      <div class="modal-overlay">
        <form class="panel w-full max-w-lg p-6 sm:p-8 m-4" method="post" action="/process">
          <div class="flex justify-between items-center mb-6 border-b border-slate-300 pb-4">
            <h2 class="metal-heading text-xl font-bold uppercase tracking-wider">Select Variables & Scope</h2>
            <a href="/" class="text-slate-400 hover:text-red-500 text-xl font-bold">&times;</a>
          </div>
          <input type="hidden" name="filename" value="<%= @filename %>">
          
          <div class="mb-5">
            <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Independent Variable (X-Axis)</label>
            <select name="x_column" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
              <% @headers.each_with_index do |header, idx| %>
                <option value="<%= idx %>"><%= header %></option>
              <% end %>
            </select>
          </div>

          <div class="mb-5">
            <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Dependent Variable (Y-Axis)</label>
            <select name="y_column" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
              <% @headers.each_with_index do |header, idx| %>
                <option value="<%= idx %>" <%= 'selected' if idx == 1 %>><%= header %></option>
              <% end %>
            </select>
          </div>

          <div class="mb-8 border-t border-slate-300 pt-5">
            <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Model Sample Limit (Prevent Overfitting/Lag)</label>
            <select name="row_limit" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
              <option value="all">Run All Cleaned Rows (Full Dataset)</option>
              <option value="100">First 100 Rows</option>
              <option value="500">First 500 Rows</option>
              <option value="1000">First 1,000 Rows</option>
            </select>
          </div>

          <button class="metal-button w-full rounded px-4 py-3 font-bold uppercase tracking-wider" type="submit">CLEAN & RUN MODEL</button>
        </form>
      </div>
    <% end %>

    <section class="grid gap-6 lg:grid-cols-[minmax(280px,380px)_1fr]">
      
      <!-- LEFT PANEL: UPLOAD AND MANUAL ENTRY -->
      <div class="panel p-5 sm:p-6 flex flex-col gap-6">
        
        <!-- FILE UPLOAD SECTOR -->
        <form method="post" action="/upload" enctype="multipart/form-data" class="border-b border-slate-300 pb-6">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">File Upload</h2>
          </div>
          <input type="file" name="dataset" accept=".csv, .xls, .xlsx" required class="w-full text-[11px] text-slate-500 file:mr-2 file:rounded file:border-0 file:bg-[#1c6da8] file:px-2 file:py-1 file:text-[11px] file:font-bold file:text-white hover:file:bg-[#164d78]">
          <button class="metal-button w-full mt-3 rounded px-4 py-2 text-xs font-bold uppercase tracking-wider transition hover:brightness-110" type="submit">READ VARIABLES</button>
        </form>

        <!-- MANUAL ENTRY SECTOR -->
        <form method="post" action="/manual" id="regression-form">
          <div class="mb-5 flex items-center justify-between">
            <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">Data Stream</h2>
            <button class="text-xs text-slate-500 underline decoration-slate-400 underline-offset-4" type="button" onclick="document.getElementById('manual-rows').innerHTML=''; addRow(); addRow();">CLEAR</button>
          </div>
          
          <div class="grid grid-cols-[1fr_1fr_42px] gap-2 mb-3 text-xs uppercase tracking-wider muted">
            <span>X input</span><span>Y input</span><span aria-hidden="true"></span>
          </div>
          <div class="space-y-2 max-h-[300px] overflow-y-auto pr-2" id="manual-rows"></div>
          
          <div class="mt-5 flex flex-wrap gap-3">
            <button class="metal-outline border px-3 py-2 text-[10px] font-bold uppercase tracking-wider transition hover:bg-sky-50" type="button" onclick="addRow()">+ ADD ROW</button>
            <button class="metal-button flex-1 px-4 py-2 text-[10px] font-bold uppercase tracking-wider transition hover:brightness-110" type="submit">RUN MODEL</button>
          </div>
          <p class="muted mt-5 text-[11px] leading-relaxed">Accepted format: integers and decimals only.</p>
        </form>
      </div>

      <script>
        const initialPoints = <%= @points.to_json %> || [];
        const rowContainer = document.getElementById('manual-rows');
        
        function addRow(xVal = '', yVal = '') {
          const row = document.createElement('div');
          row.className = 'grid grid-cols-[1fr_1fr_42px] gap-2 manual-row';
          row.innerHTML = `<input class="min-w-0 px-3 py-2 text-sm focus:border-[#1c6da8]" name="x_values[]" type="number" step="any" value="${xVal}" required><input class="min-w-0 px-3 py-2 text-sm focus:border-[#1c6da8]" name="y_values[]" type="number" step="any" value="${yVal}" required><button class="border border-slate-400 text-lg text-slate-500 hover:bg-slate-100" type="button">&times;</button>`;
          row.querySelector('button').onclick = () => { if (rowContainer.children.length > 2) row.remove(); };
          rowContainer.appendChild(row);
        }

        function renderInitial() {
          rowContainer.innerHTML = '';
          if (initialPoints.length > 0) {
            initialPoints.forEach(p => addRow(p[0] || '', p[1] || ''));
          } else {
            addRow(); addRow();
          }
        }
        renderInitial();
      </script>

      <!-- RIGHT PANEL: MODEL OUTPUT -->
      <div>
        <% if @step == 3 && @filename && @headers %>
          <div class="panel p-3 mb-4 flex items-center gap-3">
            <button class="metal-button rounded px-4 py-1 text-[10px] font-bold uppercase tracking-wider" onclick="document.getElementById('vars-modal').style.display='flex'">CHANGE VARIABLES</button>
            <% if @clean_filename %>
              <a href="/<%= @clean_filename %>" download class="metal-outline border rounded px-4 py-1 text-[10px] font-bold uppercase transition hover:bg-sky-50 ml-auto">DOWNLOAD CLEAN CSV</a>
            <% end %>
          </div>

          <!-- Hidden Change Variables Modal -->
          <div id="vars-modal" class="modal-overlay" style="display:none;">
            <form class="panel w-full max-w-lg p-6 sm:p-8 m-4" method="post" action="/process">
              <div class="flex justify-between items-center mb-6 border-b border-slate-300 pb-4">
                <h2 class="metal-heading text-xl font-bold uppercase tracking-wider">Change Variables</h2>
                <button type="button" onclick="document.getElementById('vars-modal').style.display='none'" class="text-slate-400 hover:text-red-500 text-xl font-bold">&times;</button>
              </div>
              <input type="hidden" name="filename" value="<%= @filename %>">
              
              <div class="mb-5">
                <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Independent Variable (X-Axis)</label>
                <select name="x_column" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
                  <% @headers.each_with_index do |header, idx| %>
                    <option value="<%= idx %>" <%= 'selected' if header == @x_name %>><%= header %></option>
                  <% end %>
                </select>
              </div>

              <div class="mb-8">
                <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Dependent Variable (Y-Axis)</label>
                <select name="y_column" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
                  <% @headers.each_with_index do |header, idx| %>
                    <option value="<%= idx %>" <%= 'selected' if header == @y_name %>><%= header %></option>
                  <% end %>
                </select>
              </div>

              <button class="metal-button w-full rounded px-4 py-3 font-bold uppercase tracking-wider" type="submit">UPDATE MODEL</button>
            </form>
          </div>
        <% end %>

        <section class="panel min-h-[420px] p-5 sm:p-6">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">Model Output</h2>
            <span class="metal-status text-xs"><%= @metrics ? 'STATUS: COMPLETE' : 'STATUS: AWAITING DATA' %></span>
          </div>
          <div class="relative h-[300px] sm:h-[360px]"><canvas id="regression-chart"></canvas></div>
        </section>
      </div>
    </section>

    <% if @metrics %>
      <section class="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">SLOPE / B1</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:slope]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">INTERCEPT / B0</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:intercept]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">CORRELATION / R</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:correlation]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">R-SQUARED</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:r_squared]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">SSE (ERROR)</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:sse]) %></p></div>
      </section>
      
      <p class="mt-5 text-center text-sm text-slate-600 font-bold">y = <%= format_number(@metrics[:slope]) %>x <%= @metrics[:intercept] >= 0 ? '+' : '-' %> <%= format_number(@metrics[:intercept].abs) %></p>

      <script>
        const metricPoints = <%= @points.to_json %>.map(p => ({ x: p[0], y: p[1] }));
        const minX = Math.min(...metricPoints.map(p => p.x));
        const maxX = Math.max(...metricPoints.map(p => p.x));
        const slope = <%= @metrics[:slope] %>;
        const intercept = <%= @metrics[:intercept] %>;
        
        new Chart(document.getElementById('regression-chart'), {
          type: 'scatter',
          data: { datasets: [
            { label: 'Observed data', data: metricPoints, backgroundColor: '#277db4', borderColor: '#164d78', pointRadius: 5 },
            { label: 'Line of Best Fit', data: [{x: minX, y: intercept + slope * minX}, {x: maxX, y: intercept + slope * maxX}], type: 'line', borderColor: '#d66a2c', borderWidth: 2, pointRadius: 0, tension: 0 }
          ]},
          options: { responsive: true, maintainAspectRatio: false, scales: {
            x: { type: 'linear', title: {display: true, text: "<%= @x_name %>"}, grid: { color: 'rgba(54,75,94,.14)' }, ticks: { color: '#5d6b79' } },
            y: { title: {display: true, text: "<%= @y_name %>"}, grid: { color: 'rgba(54,75,94,.14)' }, ticks: { color: '#5d6b79' } }
          }, plugins: { legend: { labels: { color: '#1c2733', font: { family: 'Rajdhani' } } } } }
        });
      </script>
    <% end %>
  </main>
</body>
</html>