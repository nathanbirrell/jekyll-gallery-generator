require 'exifr'
require 'rmagick'
include Magick

include FileUtils

$image_extensions = [".png", ".jpg", ".jpeg", ".gif"]

module Jekyll
  class GalleryImage
    include Comparable
    attr_accessor :name
    attr_accessor :path

    def initialize(name, base)
      @name = name
      @base = base
      @path = File.join(base, name)

      date_time
      exif
    end

    def <=>(b)
      cmp = @date_time <=> b.date_time
      return cmp == 0 ? @name <=> b.name : cmp
    end

    def date_time
      return @date_time if defined? @date_time
      begin
        @date_time = self.exif.date_time.to_i
      rescue Exception => e
        @date_time = 0
      end
      return @date_time
    end

    def exif
      return @exif if defined? @exif
      @exif = nil
      begin
        @exif = EXIFR::JPEG.new(@path)
      rescue EXIFR::MalformedJPEG
        puts "No EXIF data in #{@path}"
      rescue Exception => e
        puts "Error reading EXIF data for #{@path}: #{e}"
      end
      return @exif
    end

    def to_s
      return @name
    end

    def to_liquid
      # Liquid hates symbol keys. Gotta stringify them
      return {
        'name' => @name,
        'src' => "/#{@path}",
        'thumb_src' => "/#{@base}/thumbs/#{@name}",
        'date_time' => @date_time,
        'exif' => @exif && @exif.to_hash.collect{|k,v| [k.to_s, v]}.to_h,
      }
    end
  end

  class GalleryFile < StaticFile
    def write(dest)
      return false
    end
  end

  class ReadYamlPage < Page
    def read_yaml(base, name, opts = {})
      begin
        self.content = File.read(File.join(base.to_s, name.to_s), (site ? site.file_read_opts : {}).merge(opts))
        if content =~ /\A(---\s*\n.*?\n?)^((---|\.\.\.)\s*$\n?)/m
          self.content = $POSTMATCH
          self.data = SafeYAML.load($1)
        end
      rescue SyntaxError => e
        Jekyll.logger.warn "YAML Exception reading #{File.join(base.to_s, name.to_s)}: #{e.message}"
      rescue Exception => e
        Jekyll.logger.warn "Error reading file #{File.join(base.to_s, name.to_s)}: #{e.message}"
      end

      self.data ||= {}
    end
  end

  class GalleryIndex < ReadYamlPage
    def initialize(site, base, dir, galleries)
      @site = site
      @base = base
      @dir = dir.gsub("source/", "")
      @name = "index.html"
      config = site.config["gallery"] || {}

      self.process(@name) # Jekyll method to set 'basename'
      gallery_index = File.join(base, "_layouts", "gallery_index.html")
      unless File.exists?(gallery_index)
        gallery_index = File.join(File.dirname(__FILE__), "gallery_index.html")
      end
      self.read_yaml(File.dirname(gallery_index), File.basename(gallery_index))
      self.data["title"] = config["title"] || "Photos"
      self.data["galleries"] = []
      begin
        sort_field = config["sort_field"] || "date_time"
        galleries.sort! {|a,b|
          cmp = b.data[sort_field] <=> a.data[sort_field]
          # Tie goes to first alphabetically. The different order (a<=>b) is intentional.
          cmp == 0 ? a.data["name"] <=> b.data["name"] : cmp
        }
      rescue Exception => e
        puts "Error sorting galleries: #{e}"
        puts e.backtrace
      end
      if config["sort_reverse"]
        galleries.reverse!
      end
      galleries.each {|gallery|
        unless gallery.hidden
          self.data["galleries"].push(gallery.data)
        end
      }
    end
  end

  class GalleryPage < ReadYamlPage
    attr_reader :hidden

    def initialize(site, dir, gallery_name)
      @site = site
      @base = site.source
      @dir = dir.gsub("source/", "")
      @dest_dir = @dir
      @name = "index.html"
      @images = []
      @hidden = false

      config = site.config["gallery"] || {}
      gallery_config = {}
      max_size_x = 400
      max_size_y = 400

      scale_method = config['scale_method'] || 'fit'

      if config['thumbnail_size']
        max_size_x = config["thumbnail_size"]["x"] || max_size_x
        max_size_y = config["thumbnail_size"]["y"] || max_size_y
      end

      if config['galleries']
        gallery_config = config['galleries'][gallery_name] || {}
      end

      @hidden = gallery_config['hidden'] if gallery_config['hidden']

      self.process(@name) # Jekyll method to set 'basename'

      gallery_page = File.join(@base, "_layouts", "gallery_page.html")
      unless File.exists?(gallery_page)
        gallery_page = File.join(File.dirname(__FILE__), "gallery_page.html")
      end
      self.read_yaml(File.dirname(gallery_page), File.basename(gallery_page))

      gallery_title_prefix = config["title_prefix"] || 'Photos: '
      gallery_name = gallery_name.gsub(/[_-]/, " ").gsub(/\w+/) {|word| word.capitalize}
      begin
        gallery_name = gallery_config["name"] || gallery_name
      rescue Exception
      end

      thumbs_dir = File.join(site.dest, @dir, "thumbs")
      FileUtils.mkdir_p(thumbs_dir, :mode => 0755)
      date_times = {}
      entries = Dir.entries(dir)
      entries.each_with_index do |name, i|
        next if name.chars.first == "."
        next unless name.downcase().end_with?(*$image_extensions)
        image = GalleryImage.new(name, dir)
        @images.push(image)
        date_times[name] = image.date_time
        @site.static_files << GalleryFile.new(site, @base, File.join(@dir, "thumbs"), name)

        thumb_path = File.join(thumbs_dir, name)
        if File.file?(thumb_path) == false or File.mtime(image.path) > File.mtime(thumb_path)
          begin
            m_image = ImageList.new(image.path)
            m_image.auto_orient!
            m_image.send("resize_to_#{scale_method}!", max_size_x, max_size_y)
            puts "Writing thumbnail to #{thumb_path}"
            m_image.write(thumb_path)
          rescue Exception => e
            printf "Error generating thumbnail for #{image.path}: #{e}\r"
            puts e.backtrace
          end
          if i % 5 == 0
            GC.start
          end
        end

        printf "#{gallery_name} #{i+1}/#{entries.length} images\r"
      end

      begin
        @images.sort!
        if gallery_config["sort_reverse"]
          @images.reverse!
        else
          # sort by name
          @images.sort! { |a,b| a.name.downcase <=> b.name.downcase }
        end
      rescue Exception => e
        puts "Error sorting images in gallery #{gallery_name}: #{e}"
        puts e.backtrace
      end

      best_image = nil
      best_image = @images[0].name if @images.length > 0
      best_image = gallery_config["best_image"] || best_image

      if date_times.has_key?(best_image)
        gallery_date_time = date_times[best_image]
      else
        puts "#{gallery_name}: best_image #{best_image} not found!"
        gallery_date_time = 0
      end

      self.data["best_image"] = best_image
      site.static_files = @site.static_files
      self.data["gallery"] = gallery_name
      self.data["images"] = @images
      self.data["date_time"] = gallery_date_time
      self.data["name"] = gallery_name
      self.data["title"] = "#{gallery_title_prefix}#{gallery_name}"
      self.data["exif"] = {}
      self.data["sitemap"] = false if @hidden
    end
  end

  class Gallery
    attr_accessor :images

    def initialize(site, gallery_name)
      @gallery_name = gallery_name
      @dir = site.config["gallery"]["dir"] || "photos"
      @dir = "#{@dir}/#{@gallery_name}"
      @read_dir = "_site/#{@dir}"
      @images = self.getImages
    end

    def getImages
      @images = []

      unless File.directory?(@read_dir)
        puts "Couldn't find gallery by name: #{@gallery_name}"
        return @images
      end

      files = Dir.entries(@read_dir)
      files.each_with_index do |name, i|
        next if name.chars.first == '.'
        next unless name.downcase.end_with?(*$image_extensions)
        image = GalleryImage.new(name, @dir)
        @images.push(image)
      end

      @images
    end
  end

  class GalleryIndexPage
    def initialize(site)
      config = site.config["gallery"] || {}
      dir = config["dir"] || "photos"
      galleries = []
      original_dir = Dir.getwd
      Dir.chdir(site.source)
      begin
        Dir.foreach(dir) do |gallery_dir|
          gallery_path = File.join(dir, gallery_dir)
          if File.directory?(gallery_path) and gallery_dir.chars.first != "."
            gallery = GalleryPage.new(site, gallery_path, gallery_dir)
            gallery.render(site.layouts, site.site_payload)
            gallery.write(site.dest)
            site.pages << gallery
            galleries << gallery
          end
        end
      rescue Exception => e
        puts "Error generating galleries: #{e}"
        puts e.backtrace
      end
      Dir.chdir(original_dir)

      gallery_index = GalleryIndex.new(site, site.source, dir, galleries)
      gallery_index.render(site.layouts, site.site_payload)
      gallery_index.write(site.dest)

      site.pages << gallery_index
    end
  end

  class GalleryGenerator < Generator
    safe true

    def generate(site)
      GalleryIndexPage.new(site)
    end
  end

  class GalleryLiquidTag < Liquid::Tag
    def initialize(tag_name, text, tokens)
      super
      @text = text.strip
    end
    def render(context)
      site = context.registers[:site]
      gallery_name = context.registers[:page]['gallery_name'] || @text
      template = File.read File.join Dir.pwd, '_includes', 'gallery.html'
      galleries_dir = site.config['gallery']['dir'] || 'photos'
      gallery_dir = "#{galleries_dir}/#{gallery_name}"
      @images = []

      if File.directory?(gallery_dir) && !gallery_name.empty?
        @images = Gallery.new(site, gallery_name).images
        template = (Liquid::Template.parse template).render('images' => @images)
      else
        puts "No gallery found for: #{context.registers[:page]['path']}"
        puts "Set 'gallery_name' in frontmatter or as an argument to this tag"
      end

      template
    end
  end
  Liquid::Template.register_tag('gallery', Jekyll::GalleryLiquidTag)
end
