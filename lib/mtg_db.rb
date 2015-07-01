require "mtg_db/version"
require 'mtg_db/downloaders'
require 'mtg_db/parsers'
require 'mechanize'
require 'sqlite3'
require 'sequel'
require 'active_support/inflector'

module MtgDb
  TMP_DIR = '/tmp/mtg'
  ALL_CARDS_DIR = 'standard'
  DOUBLE_FACED_DIR = 'double-faced'
  SCHEMA_FILENAME = File.join(__dir__, '..', 'sql', 'cards.schema.sql')

  @@standard_files_downloaded = nil

  def self.create_db(name)
    schema = File.new(SCHEMA_FILENAME).readlines.join
    db = SQLite3::Database.new(name)
    rows = db.execute_batch(schema)
    db.close
  end

  # Downloading
  # NOTE: The download directory must be empty for downloads to start
  def self.download_all_cards(tmp_dir)
    tmp_dir ||= TMP_DIR
    tmp_dir = File.join(tmp_dir, 'standard')

    downloader = MtgDb::Downloaders::AllCardsStandardDownloader.new(:output_dir => tmp_dir)
    downloader.start if downloader.is_empty?
    @@standard_files_downloaded = downloader.files
  end

  def self.add_all_cards_to_db(db_filename, tmp_dir)
    # Connect to db
    db = Sequel.sqlite(db_filename)
    #db.loggers << Logger.new($stdout)
    db.run "PRAGMA synchronous = 0"
    require 'mtg_db/models'

    tmp_dir ||= TMP_DIR
    tmp_dir = File.join(tmp_dir, 'standard')

    # Parsing
    agent = Mechanize.new
    agent.pluggable_parser.html = MtgDb::Parsers::GathererParser

    @@standard_files_downloaded.each do |file|
      filepath = File.absolute_path file
      uri = "file://#{filepath}"

      page = agent.get(uri) # uses our pluggable parser

      # insert each card into the db, creating records in associated tables if necessary
      page.cards.each do |card|
        puts "\tProcessing Card: #{card[:name]}"

        card_model = MtgDb::Models::Card.new
        card_model.set_fields(card, [:name, :mana_cost, :cmc, :supertype, :subtype, :rules, :power, :toughness])
        card_model.save

        # Set/Rarity a.k.a Set Version
        card[:set_versions].each do |set_version|
          set = MtgDb::Models::CardSet.find_or_create(:name => set_version[:set], :abbreviation => set_version[:set_abbreviation])
          rarity = MtgDb::Models::Rarity.find_or_create(:name => set_version[:rarity], :abbreviation => set_version[:rarity][0])
          MtgDb::Models::SetVersion.create(:card => card_model, :multiverse_id => set_version[:multiverse_id], :card_set => set, :rarity => rarity)
        end

        # Planeswalker
        if card_model.is_planeswalker?
          MtgDb::Models::Planeswalker.create(:card => card_model, :loyalty => card[:loyalty])
        end

        # Vanguard
        if card_model.is_vanguard?
          MtgDb::Models::Vanguard.create(:card => card_model, :hand_modifier => card[:hand_modifier], :life_modifier => card[:life_modifier])
        end
      end
    end
  end
  
  # Downloading
  def self.download_double_faced_cards(db_filename, tmp_dir)
    tmp_dir ||= TMP_DIR
    tmp_dir = File.join(tmp_dir, DOUBLE_FACED_DIR)

    downloader = MtgDb::Downloaders::CardDetailsDownloader.new(:output_dir => tmp_dir)
    
    # Connect to db
    db = Sequel.sqlite(db_filename)
    #db.loggers << Logger.new($stdout)
    require 'mtg_db/models'

    cards = MtgDb::Models::Card.where(Sequel.ilike(:rules, '%transform%')).all
    cards.each do |card|
      multiverse_id = card.set_versions.first.multiverse_id
      puts "#{card.name}, #{multiverse_id.to_s}"
      downloader.start(card.name.parameterize, multiverse_id)
    end
  end
  
  def self.add_double_faced_cards_to_db(db_filename, tmp_dir)
    tmp_dir ||= TMP_DIR
    tmp_dir = File.join(tmp_dir, DOUBLE_FACED_DIR)
    files = Dir.glob(File.join(tmp_dir, '*.html')).sort

    agent = Mechanize.new
    agent.pluggable_parser.html = MtgDb::Parsers::DoubleFacedCardDetailsParser

    # Connect to db
    db = Sequel.sqlite(db_filename)
    #db.loggers << Logger.new($stdout)
    require 'mtg_db/models'

    files.each do |file|
      filepath = File.absolute_path file
      uri = "file://#{filepath}"
      puts uri

      page = agent.get(uri) # uses our pluggable parser

      # insert each card into the db, creating records in associated tables if necessary
      if page.cards.size == 2
        faceup_card = MtgDb::Models::Card.where(:name => page.faceup_card_name).first
        facedown_card = MtgDb::Models::Card.where(:name => page.facedown_card_name).first

        puts "\tProcessing Double-Faced Card: #{faceup_card.name} <=> #{facedown_card.name}"
        model = MtgDb::Models::DoubleFaced.find_or_create(:faceup_card => faceup_card, :facedown_card => facedown_card)
      end
    end
  end
end
