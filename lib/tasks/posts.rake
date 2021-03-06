# frozen_string_literal: true

require 'file_store/local_store'

desc 'Update each post with latest markdown'
task 'posts:rebake' => :environment do
  ENV['RAILS_DB'] ? rebake_posts : rebake_posts_all_sites
end

task 'posts:rebake_uncooked_posts' => :environment do
  uncooked = Post.where(baked_version: nil)

  rebaked = 0
  total = uncooked.count

  uncooked.find_each do |post|
    rebake_post(post)
    print_status(rebaked += 1, total)
  end

  puts "", "#{rebaked} posts done!", ""
end

desc 'Update each post with latest markdown and refresh oneboxes'
task 'posts:refresh_oneboxes' => :environment do
  ENV['RAILS_DB'] ? rebake_posts(invalidate_oneboxes: true) : rebake_posts_all_sites(invalidate_oneboxes: true)
end

desc 'Rebake all posts with a quote using a letter_avatar'
task 'posts:fix_letter_avatars' => :environment do
  return unless SiteSetting.external_system_avatars_enabled

  search = Post.where("user_id <> -1")
    .where("raw LIKE '%/letter\_avatar/%' OR cooked LIKE '%/letter\_avatar/%'")

  rebaked = 0
  total = search.count

  search.find_each do |post|
    rebake_post(post)
    print_status(rebaked += 1, total)
  end

  puts "", "#{rebaked} posts done!", ""
end

desc 'Rebake all posts matching string/regex and optionally delay the loop'
task 'posts:rebake_match', [:pattern, :type, :delay] => [:environment] do |_, args|
  args.with_defaults(type: 'string')
  pattern = args[:pattern]
  type = args[:type]&.downcase
  delay = args[:delay]&.to_i

  if !pattern
    puts "ERROR: Expecting rake posts:rebake_match[pattern,type,delay]"
    exit 1
  elsif delay && delay < 1
    puts "ERROR: delay parameter should be an integer and greater than 0"
    exit 1
  elsif type != 'string' && type != 'regex'
    puts "ERROR: Expecting rake posts:rebake_match[pattern,type] where type is string or regex"
    exit 1
  end

  search = Post.raw_match(pattern, type)

  rebaked = 0
  total = search.count

  search.find_each do |post|
    rebake_post(post)
    print_status(rebaked += 1, total)
    sleep(delay) if delay
  end

  puts "", "#{rebaked} posts done!", ""
end

def rebake_posts_all_sites(opts = {})
  RailsMultisite::ConnectionManagement.each_connection do |db|
    rebake_posts(opts)
  end
end

def rebake_posts(opts = {})
  puts "Rebaking post markdown for '#{RailsMultisite::ConnectionManagement.current_db}'"

  begin
    disable_edit_notifications = SiteSetting.disable_edit_notifications
    SiteSetting.disable_edit_notifications = true

    total = Post.count
    rebaked = 0
    batch = 1000
    Post.update_all('baked_version = NULL')

    (0..(total - 1).abs).step(batch) do |i|
      Post.order(id: :desc).offset(i).limit(batch).each do |post|
        rebake_post(post, opts)
        print_status(rebaked += 1, total)
      end
    end
  ensure
    SiteSetting.disable_edit_notifications = disable_edit_notifications
  end

  puts "", "#{rebaked} posts done!", "-" * 50
end

def rebake_post(post, opts = {})
  post.rebake!(opts)
rescue => e
  puts "", "Failed to rebake (topic_id: #{post.topic_id}, post_id: #{post.id})", e, e.backtrace.join("\n")
end

def print_status(current, max)
  print "\r%9d / %d (%5.1f%%)" % [current, max, ((current.to_f / max.to_f) * 100).round(1)]
end

desc 'normalize all markdown so <pre><code> is not used and instead backticks'
task 'posts:normalize_code' => :environment do
  lang = ENV['CODE_LANG'] || ''
  require 'import/normalize'

  puts "Normalizing"
  i = 0
  Post.where("raw like '%<pre>%<code>%'").each do |p|
    normalized = Import::Normalize.normalize_code_blocks(p.raw, lang)
    if normalized != p.raw
      p.revise(Discourse.system_user, raw: normalized)
      putc "."
      i += 1
    end
  end

  puts
  puts "#{i} posts normalized!"
end

def remap_posts(find, type, ignore_case, replace = "")
  ignore_case = ignore_case == 'true'
  i = 0

  Post.raw_match(find, type).find_each do |p|
    regex =
      case type
      when 'string' then
        Regexp.new(Regexp.escape(find), ignore_case)
      when 'regex' then
        Regexp.new(find, ignore_case)
      end

    new_raw = p.raw.gsub(regex, replace)

    if new_raw != p.raw
      begin
        p.revise(Discourse.system_user, { raw: new_raw }, bypass_bump: true, skip_revision: true)
        putc "."
        i += 1
      rescue
        puts "\nFailed to remap post (topic_id: #{p.topic_id}, post_id: #{p.id})\n"
      end
    end
  end

  i
end

desc 'Remap all posts matching specific string'
task 'posts:remap', [:find, :replace, :type, :ignore_case] => [:environment] do |_, args|
  require 'highline/import'

  args.with_defaults(type: 'string', ignore_case: 'false')
  find = args[:find]
  replace = args[:replace]
  type = args[:type]&.downcase
  ignore_case = args[:ignore_case]&.downcase

  if !find
    puts "ERROR: Expecting rake posts:remap['find','replace']"
    exit 1
  elsif !replace
    puts "ERROR: Expecting rake posts:remap['find','replace']. Want to delete a word/string instead? Try rake posts:delete_word['word-to-delete']"
    exit 1
  elsif type != 'string' && type != 'regex'
    puts "ERROR: Expecting rake posts:remap['find','replace',type] where type is string or regex"
    exit 1
  elsif ignore_case != 'true' && ignore_case != 'false'
    puts "ERROR: Expecting rake posts:remap['find','replace',type,ignore_case] where ignore_case is true or false"
    exit 1
  else
    confirm_replace = ask("Are you sure you want to replace all #{type} occurrences of '#{find}' with '#{replace}'? (Y/n)")
    exit 1 unless (confirm_replace == "" || confirm_replace.downcase == 'y')
  end

  puts "Remapping"
  total = remap_posts(find, type, ignore_case, replace)
  puts "", "#{total} posts remapped!", ""
end

desc 'Delete occurrence of a word/string'
task 'posts:delete_word', [:find, :type, :ignore_case] => [:environment] do |_, args|
  require 'highline/import'

  args.with_defaults(type: 'string', ignore_case: 'false')
  find = args[:find]
  type = args[:type]&.downcase
  ignore_case = args[:ignore_case]&.downcase

  if !find
    puts "ERROR: Expecting rake posts:delete_word['word-to-delete']"
    exit 1
  elsif type != 'string' && type != 'regex'
    puts "ERROR: Expecting rake posts:delete_word[pattern, type] where type is string or regex"
    exit 1
  elsif ignore_case != 'true' && ignore_case != 'false'
    puts "ERROR: Expecting rake posts:delete_word[pattern, type,ignore_case] where ignore_case is true or false"
    exit 1
  else
    confirm_delete = ask("Are you sure you want to remove all #{type} occurrences of '#{find}'? (Y/n)")
    exit 1 unless (confirm_delete == "" || confirm_delete.downcase == 'y')
  end

  puts "Processing"
  total = remap_posts(find, type, ignore_case)
  puts "", "#{total} posts updated!", ""
end

desc 'Delete all likes'
task 'posts:delete_all_likes' => :environment do

  post_actions = PostAction.where(post_action_type_id: PostActionType.types[:like])

  likes_deleted = 0
  total = post_actions.count

  post_actions.each do |post_action|
    begin
      post_action.remove_act!(Discourse.system_user)
      print_status(likes_deleted += 1, total)
    rescue
      # skip
    end
  end

  UserStat.update_all(likes_given: 0, likes_received: 0) # clear user likes stats
  DirectoryItem.update_all(likes_given: 0, likes_received: 0) # clear user directory likes stats
  puts "", "#{likes_deleted} likes deleted!", ""
end

desc 'Defer all flags'
task 'posts:defer_all_flags' => :environment do

  active_flags = FlagQuery.flagged_post_actions('active')

  flags_deferred = 0
  total = active_flags.count

  active_flags.each do |post_action|
    begin
      PostAction.defer_flags!(Post.find(post_action.post_id), Discourse.system_user)
      print_status(flags_deferred += 1, total)
    rescue
      # skip
    end
  end

  puts "", "#{flags_deferred} flags deferred!", ""
end

desc 'Refreshes each post that was received via email'
task 'posts:refresh_emails', [:topic_id] => [:environment] do |_, args|
  posts = Post.where.not(raw_email: nil).where(via_email: true)
  posts = posts.where(topic_id: args[:topic_id]) if args[:topic_id]

  updated = 0
  total = posts.count

  posts.find_each do |post|
    begin
      receiver = Email::Receiver.new(post.raw_email)

      body, elided = receiver.select_body
      body = receiver.add_attachments(body || '', post.user)
      body << Email::Receiver.elided_html(elided) if elided.present?

      post.revise(Discourse.system_user, { raw: body, cook_method: Post.cook_methods[:regular] },
                  skip_revision: true, skip_validations: true, bypass_bump: true)
    rescue
      puts "Failed to refresh post (topic_id: #{post.topic_id}, post_id: #{post.id})"
    end

    updated += 1

    print_status(updated, total)
  end

  puts "", "Done. #{updated} posts updated.", ""
end

desc 'Reorders all posts based on their creation_date'
task 'posts:reorder_posts', [:topic_id] => [:environment] do |_, args|
  Post.transaction do
    # update sort_order and flip post_number to prevent
    # unique constraint violations when updating post_number
    builder = DB.build(<<~SQL)
      WITH ordered_posts AS (
          SELECT
            id,
            ROW_NUMBER()
            OVER (
              PARTITION BY topic_id
              ORDER BY created_at, post_number ) AS new_post_number
          FROM posts
          /*where*/
      )
      UPDATE posts AS p
      SET sort_order = o.new_post_number,
        post_number  = p.post_number * -1
      FROM ordered_posts AS o
      WHERE p.id = o.id AND
            p.post_number <> o.new_post_number
    SQL
    builder.where("topic_id = :topic_id") if args[:topic_id]
    builder.exec(topic_id: args[:topic_id])

    DB.exec(<<~SQL)
      UPDATE notifications AS x
      SET post_number = p.sort_order
      FROM posts AS p
      WHERE x.topic_id = p.topic_id AND
            x.post_number = ABS(p.post_number) AND
            p.post_number < 0
    SQL

    DB.exec(<<~SQL)
      UPDATE post_timings AS x
      SET post_number = x.post_number * -1
      FROM posts AS p
      WHERE x.topic_id = p.topic_id AND
            x.post_number = ABS(p.post_number) AND
            p.post_number < 0;

      UPDATE post_timings AS t
      SET post_number = p.sort_order
      FROM posts AS p
      WHERE t.topic_id = p.topic_id AND
            t.post_number = p.post_number AND
            p.post_number < 0;
    SQL

    DB.exec(<<~SQL)
      UPDATE posts AS x
      SET reply_to_post_number = p.sort_order
      FROM posts AS p
      WHERE x.topic_id = p.topic_id AND
            x.reply_to_post_number = ABS(p.post_number) AND
            p.post_number < 0;
    SQL

    DB.exec(<<~SQL)
      UPDATE topic_users AS x
        SET last_read_post_number = p.sort_order
      FROM posts AS p
      WHERE x.topic_id = p.topic_id AND
            x.last_read_post_number = ABS(p.post_number) AND
            p.post_number < 0;

      UPDATE topic_users AS x
        SET highest_seen_post_number = p.sort_order
      FROM posts AS p
      WHERE x.topic_id = p.topic_id AND
            x.highest_seen_post_number = ABS(p.post_number) AND
            p.post_number < 0;

      UPDATE topic_users AS x
        SET last_emailed_post_number = p.sort_order
      FROM posts AS p
      WHERE x.topic_id = p.topic_id AND
            x.last_emailed_post_number = ABS(p.post_number) AND
            p.post_number < 0;
    SQL

    # finally update the post_number
    DB.exec(<<~SQL)
      UPDATE posts
      SET post_number = sort_order
      WHERE post_number < 0
    SQL
  end

  puts "", "Done.", ""
end

def missing_uploads
  old_scheme_upload_count = 0

  missing = Post.find_missing_uploads do |post, src, path, sha1|
    next if sha1.present?

    upload_id = nil

    # recovering old scheme upload.
    local_store = FileStore::LocalStore.new
    public_path = "#{local_store.public_dir}#{path}"
    file_path = nil

    if File.exists?(public_path)
      file_path = public_path
    else
      tombstone_path = public_path.sub("/uploads/", "/uploads/tombstone/")
      file_path = tombstone_path if File.exists?(tombstone_path)
    end

    if file_path.present?
      tmp = Tempfile.new
      tmp.write(File.read(file_path))
      tmp.rewind

      if upload = UploadCreator.new(tmp, File.basename(path)).create_for(Discourse.system_user.id)
        upload_id = upload.id
        DbHelper.remap(UrlHelper.absolute(src), upload.url)

        post.reload
        post.raw.gsub!(src, upload.url)
        post.cooked.gsub!(src, upload.url)

        if post.changed?
          post.save!(validate: false)
          post.rebake!
        end
      end

      FileUtils.rm(tmp, force: true)
    else
      old_scheme_upload_count += 1
    end

    upload_id
  end

  puts "Database name: #{RailsMultisite::ConnectionManagement.current_db}"
  puts "", "#{missing[:count]} post uploads are missing.", ""

  if missing[:count] > 0
    puts "#{missing[:uploads].count} uploads are missing."
    puts "#{old_scheme_upload_count} of #{missing[:uploads].count} are old scheme uploads." if old_scheme_upload_count > 0
    puts "#{missing[:post_uploads].count} of #{Post.count} posts are affected.", ""

    if ENV['VERBOSE'] == "1"
      puts "missing uploads!"
      missing[:uploads].each do |path|
        puts "#{path}"
      end

      if missing[:post_uploads].count > 0
        puts
        puts "Posts with missing uploads"
        missing[:post_uploads].each do |id, uploads|
          post = Post.with_deleted.find_by(id: id)
          if post
            puts "#{post.url} missing #{uploads.join(", ")}"
          else
            puts "could not find post #{id}"
          end
        end
      end
    end
  end

  missing[:count] == 0
end

desc 'Finds missing post upload records from cooked HTML content'
task 'posts:missing_uploads', [:single_site] => :environment do |_, args|
  if args[:single_site].to_s.downcase == "single_site"
    missing_uploads
  else
    RailsMultisite::ConnectionManagement.each_connection do
      missing_uploads
    end
  end
end
