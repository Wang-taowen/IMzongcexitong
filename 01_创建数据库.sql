-- MySQL 8.4 · 学生综合测评数据库 · 在新库中执行
-- 3NF 优化版：删除为"复合外键钉住 rule_id"引入的冗余属性，全部表至少满足 3NF
-- 与原版的差异：
--   application_form  删除 rule_id（year_id → rule_id 违反 2NF）
--   application_item  删除 rule_id（form_id/project_id → rule_id 传递依赖违反 3NF）
--   assessment_result 删除 rule_id（2NF）、grade（(rule_id,total_score) → grade 违反 3NF）
--   project_score     删除 rule_id（2NF）、weighted_score（(project_id,approved_score) → weighted_score 违反 3NF）
--   privacy_access_log 删除 login_account（reviewer_id → login_account 违反 3NF）
--   evidence.sha256  保留为 VIRTUAL 生成列并建索引（派生值不落盘，不违反 3NF；v8 曾移除，v10 恢复）
--   academic_year / assessment_project 删除冗余 UNIQUE 复合键（原仅为复合外键提供索引）
--   新增 application_item 触发器，替代原复合外键对"条目项目与表单学年规则一致"的声明式约束
--   等级 grade 与加权分 weighted_score 改为在视图/存储过程中按规则实时计算
-- 设计优化 v2（2026-11-16）：
--   student_year_assessment 删除 status 列（与 application_form.status 双份冗余状态，
--     相应同步 UPDATE 一并移除，申报状态一律以 application_form 为准）
--   student / reviewer 新增跨表登录名互斥触发器（防止同一数据库账号既申报又审核）
--   review_item 终审核定分增加 score_cap 封顶校验（不再由 publish 静默截断）
--   withdraw_item 同时将条目证明材料置为 inactive（避免撤回后材料滞留）
--   privacy_access_log 增加 (reviewer_id, accessed_at) 审计索引
--   assessment_rule 增加 parent_rule_id 自引用外键（规则版本链追溯）
-- 特色功能 v3（2026-11-16）：
--   新增过程 review_item_diff：驳回重提对比，把最近一次驳回快照与当前条目并排输出，
--     字段级标出改动（项目、细节、申报分、发生日期、附件数量），审核人一眼定位改动
--   新增视图 student_progress（跨学年个人进展，LAG 窗口函数）与聚合视图
--     class_progress_stats（班级进步统计，不含个人标识），过程 my_progress（学生自查）
--   新增事件 open_due_years / review_due_years：由 MySQL 事件调度器自动推进学年状态
--     （到开放时刻自动开启、过截止时刻自动转入审核），应用层不再手工切换
-- 补齐原始需求缺口 v4（2026-11-19）：
--   新增提交记录表 submission_log：submit_form 每次提交留痕（轮次、时间；条目快照 v8 起拆到子表）
--   新增公示视图 public_notice：仅学年 published（全部审核完成、统计结束）后可见，
--     含学号姓名供全体学生查看；原 published_results 匿名口径仍供分析员使用
--   新增过程 my_evidence（学生查看本人证明材料清单，仅元数据不含文件内容）、
--     my_submission_history（学生查看本人各轮提交记录）
--   新增角色 sa_admin：主数据可读写（触发器继续守住不变量），业务数据只读监控；
--     证明材料仅授权元数据列（不含 file_body），隐私访问日志可查
--   新增过程 abandon_form：申报截止后管理员可作废未完成表单（status → void），
--     避免个别学生卡死整学年公示；是否公示一律以 deadline 为依据
-- 实现细节风险点加固 v5（2026-11-19）：
--   review_item 终审通过时校验"同表单同项目已通过条目核定分合计 + 本次核定分 ≤ 封顶分"，
--     并锁定同表单全部条目串行化终审，从源头消除 calculation_input 的 LEAST 静默截断
--   application_item 触发器新增硬性校验：申报分不得超过项目封顶分（减轻人工审核负担）
--   keep_year_rule 新增：学年启用后不可修改起止日期与开放时刻；同状态下截止时间
--     只许后延（open→review 的同一句 UPDATE 允许把截止时间提前到当前时刻，
--     即 02 演示数据所用的"手工提前关闭申报"快进模式）
--   student_progress 增加 rule_id/version_no 列，提示跨学年分数差的可比性
--   排名改用 DENSE_RANK：同分并列且名次连续（1,1,2），避免 RANK 的名次空洞（1,1,3）
-- 基础问题收尾 v6（2026-11-20）：
--   完整性：academic_year 防日期区间重叠触发器；assessment_project 权重合计≤1 编辑期校验
--   审计闭环：access_denied_log（越权尝试失败也留痕，审核过程在回滚后补记，SIGNAL 消息不变）；
--     admin_operation_log（abandon_form/publish_year 过程内记录 + 6 张主数据表 18 个 AFTER 触发器，
--     学年状态变更 old→new 全程留痕；EVENT 自动推进时操作者记为事件定义者账号）
--   运维：event_scheduler 改 SET PERSIST（重启不丢）；admin_stalled_forms 视图定位卡公示的表单
--   配套（仓库同步目录）：demo.py 增 sa_demo_admin 账号与 --event-scheduler=ON 启动参数；
--     02 追加新功能展示查询；tests/test_constraints.py 约束负例套件；使用说明.md 全面同步
-- 加分创新点 v7（2026-11-21，最小侵入：不改任何现有表的列与现有过程的结果集）：
--   公示校验码：publication_batch 独立表存公示批次的 SHA-256 承诺（不挂在 academic_year 上，
--     避免把"公示批次"属性混入学年实体；任何角色无写权限，落盘即不可改）；
--     publish_year 同事务计算并写入，verify_publication 供全体角色重算比对（intact 标志）
--   材料查重：按 file_body 的 SHA-256 计算（v10 恢复 VIRTUAL 生成列+索引，查重走索引等值连接）；check_evidence_duplicates 供审核人看本条目附件
--     的全库重复份数（只给计数，不暴露他人身份；软提示不硬拦截，合法复用仍由审核人采信）；
--     evidence_duplicates 管理视图按指纹分组
--   规则版本链：rule_version_chain 递归视图沿 parent_rule_id 展开根版本/链深/路径；
--     assessment_rule 增 CHECK 禁止自环（parent_rule_id <> rule_id）
--   状态变更日志：status_change_log 表 + 学年/表单/条目 3 个 AFTER UPDATE 单语句触发器，
--     仅 status 实际迁移时留痕（old→new + 操作账号），与 admin_operation_log 分工互补
-- 严格 3NF 化 v8（2026-11-23，为消除 2NF/3NF 违例与半结构化列而调整列与快照结构）：
--   assessment_result 去掉 generated_at（改用 academic_year.published_at）与 rank_no；
--     排名独立成 assessment_ranking，避免 rank_no 依赖非主属性 total_score，
--     也消除 year_id → generated_at 对候选键 (student_id, year_id) 的部分依赖（原 2NF 违例）
--   submission_log 去掉 item_count 与 snapshot JSON，条目快照拆到 submission_snapshot_item，
--     条目数由子表 COUNT 得出（原 snapshot → item_count 为非主属性决定非主属性）
--   review_record 去掉 reviewed_item JSON，拆到 review_snapshot_item 与
--     review_snapshot_evidence，消除 JSON 嵌套列带来的 1NF 争议
--   evidence 去掉 sha256 生成列，查重与校验时按 SHA2(file_body, 256) 实时计算
--   目标：全部基表满足 1NF（无 JSON 嵌套列）、2NF 与 3NF（无非主属性决定非主属性）
-- 真实口径 + AI 初审 v9（2026-11-23）：
--   按北大信管 24 级及以前 / 25 级及以后细则改为 S=A(20)+B1(80)+B2+C；
--   B1 由规则 b1_formula 决定（绩点×20 或加权平均分×0.8），A/B1 作为基础分录入；
--   B2/C 为加分项目，支持单项上限、条数上限和项目总上限；
--   结果只有优秀/合格/不合格，优秀人数按年级 FLOOR(人数×excellent_ratio)；
--   新增 component_score（A/B1/B2/C 分项）与 ai_review（AI/规则初审草稿）；
--   移除 project_score 与项目权重，旧学年单规则改为按学生入学年匹配规则。
-- 隐私/越权/效率/并列排名修复 v10（2026-11-26，在组员 v9 基础上仅修这四项，其余问题暂搁置）：
--   隐私：published_results 恢复匿名口径（去掉 student_id/rule_id，仅留 result_id/学年/班级/年级/总分/等级/名次），
--     供 sa_analyst 分析；含学号姓名的公示走 public_notice；年级内名次与等级在内部视图 result_with_rank 统一计算
--   越权：web_ai_draft / web_save_ai_draft 补 lock_review_item 范围校验 + privacy_access_log 留痕 +
--     越权失败 access_denied_log 补记（与 web_ai_context 同口径），杜绝跨班级/未绑定账号读取或写入 AI 草稿
--   效率：恢复 evidence.sha256 VIRTUAL 生成列 + KEY(sha256)；查重/校验改走索引等值连接，
--     不再对全表 MEDIUMBLOB 逐行 SHA2（虚拟列派生不落盘，不违反 3NF，核心组件仍满足范式）
--   并列排名：publish_year 的 ROW_NUMBER 改回 DENSE_RANK，同分并列且名次连续（1,1,2），不取消并列
-- 规范化与口径加固 v11（2026-11-26，在 v10 基础上做 3NF 收尾、让规则满分真正生效、优秀评选与基础分守卫）：
--   3NF（C1，保证效能）：assessment_project.component 由 rule_key 函数决定（传递依赖），改为 VIRTUAL 生成列
--     （派生不落盘、仍可查询并建索引，同 evidence.sha256 口径）；assessment_ranking 去掉冗余 grade_year
--     （入学年不可变、已由 student 决定），主键改 (year_id, student_id)，年级口径排名/展示时经 student 连接取得。
--     其余 apparent 冗余（建档班级/规则快照、审核时角色/轮次快照、公示冻结分项）均为可变属性快照或实时计算，保留。
--   规则满分生效（C2）：a_cap/b1_cap 不再被硬编码 20/80 架空——student_year_assessment.a_score 与 component_score
--     的行内 CHECK 仅守非负，A/B1 上限改由 set_base_assessment 按规则校验 + check_component_cap_ins 触发器按规则封顶；
--     publish_year 发布前校验也改为按各生规则 a_cap/b1_cap 比对（B1 换算倍率 ×20/×0.8 仍由 b1_formula 决定，不变）。
--   优秀评选（D1）：不合格学生不占优秀名额——合格学生在本年级"合格组"内单独 DENSE_RANK 竞争名额，
--     名额分母仍按年级总人数 FLOOR(总人数×excellent_ratio)；展示名次仍取全年级 DENSE_RANK，并列与连续名次不变。
--   基础分守卫（D2）：set_base_assessment 增学年状态守卫（学年须存在、已公示后基础分冻结）；
--     规则版本稳定——已建档沿用建档时锁定的规则版本，不随后续规则更新漂移，仅未建档才按入学年匹配最新规则。
--   授权口径（A2）：web_ai_draft 去掉 sa_admin 的 EXECUTE（其经 lock_review_item 限定绑定审核员，管理员调用必被拒），
--     与 web_save_ai_draft 同口径；管理员经 ai_review 的 SELECT 只读监控。
--   配套：02 演示查询改读匿名 published_results（去掉 student_id，A1）并去掉项目 INSERT 的 component 列（C1 虚拟列）；
--     scoring.py 口径补齐（D3：论文通讯作者、竞赛类别 A/B）；tests 补 AI 越权负例与学生材料 403（E）。
--   暂不修（A3）：DENSE_RANK 并列恰好落在优秀名额边界时可能轻微超额——为保留"不取消并列"的既定取舍，接受该边界。
-- 安全/性能/功能/3NF 收尾 v12（2026-11-26）：
--   安全：S1 公示校验码覆盖等级评定输入——calc_publication_digest 摘要纳入 grade_year/a_failed/academic_failed/excellent_ratio，
--     杜绝公示后改入学年等无声改变优秀/合格而校验码仍显示完好；
--   S2 keep_year_rule 增发布守卫——转入 published 时必须已存在 publication_batch（只能经 publish_year），
--     防止直接 UPDATE 置 published 绕过计分与校验码；
--   S3 scoring.py 系统提示标注 details/evidence 为不可信数据以抵御提示注入；S4 SECRET_KEY 支持 SA_SECRET_KEY 环境变量。
--   性能（先做数据库硬指标）：P1 review_queue 先解析审核人 scope 再以常量等值连接，恢复 (year_id,class_id) 索引
--     可用（原 r.class_id IS NULL OR r.class_id=a.class_id 迫使全扫）；P2 verify_login 显式关闭连接；
--     P3 web_ai_context 提高 group_concat 上限；application_form 增 KEY(year_id,status) 覆盖按学年+状态扫描。
--   功能：F1 set_base_assessment 事务化（校验失败即回滚，不留下半写空分档案），abandon_form 作废时把空基础分记 0
--     以免阻塞整学年公示，publish_year 空分提示改为准确的测评档案口径；F2 calculation_input 计入 completed 表单
--     （公示后视图不再误显示 0；void 作废仍不计加分，属既定口径）；F3 规则匹配增加 effective_on <= UTC_DATE()。
--   3NF（N1）：assessment_project.category 由 rule_key 函数决定（传递依赖），改为 VIRTUAL 生成列（与 component 同口径）。
-- 完整性收尾 v13（2026-11-27，在 v12 基础上仅补三处硬约束，不改任何表结构与结果集列名）：
--   N2 rule_key 白名单 CHECK：component/category 两个生成列的唯一输入必须合法；
--     否则拼错键会被 CASE 的 ELSE 静默归为 B2/学术科研，错误归类且应用层毫无察觉。
--   S5 公示校验码纳入 a.class_id：public_notice 与 published_results 都展示班级，
--     公示后改班级快照必须让 verify_publication 显示 intact=0（与已覆盖的 grade_year 同口径）。
--   C3 component_score 补 BEFORE UPDATE 封顶触发器：原 INSERT-only 触发器拦不住
--     公示后直接 UPDATE 改 A/B1 分数绕过规则满分，UPDATE 同样按该生该年规则校验。
CREATE DATABASE student_assessment CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE student_assessment;

CREATE TABLE class_group (
    class_id VARCHAR(24) PRIMARY KEY,
    class_name VARCHAR(100) NOT NULL
) COMMENT='班级';

CREATE TABLE student (
    student_id VARCHAR(24) PRIMARY KEY,
    student_name VARCHAR(80) NOT NULL,
    class_id VARCHAR(24) NOT NULL,
    grade_year SMALLINT UNSIGNED NOT NULL COMMENT '入学年，用于区分24级及以前/25级及以后规则',
    login_name VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,
    CHECK (login_name REGEXP '^[A-Za-z0-9_]+$' AND grade_year BETWEEN 2000 AND 2100),
    KEY (grade_year),
    FOREIGN KEY (class_id) REFERENCES class_group(class_id)
) COMMENT='学生';

CREATE TABLE assessment_rule (
    rule_id INT UNSIGNED PRIMARY KEY,
    rule_name VARCHAR(100) NOT NULL,
    version_no VARCHAR(30) NOT NULL,
    cohort ENUM('le2024','ge2025') NOT NULL COMMENT '适用于24级及以前/25级及以后',
    b1_formula ENUM('gpa_x20','weighted_x08') NOT NULL COMMENT '24级：平均绩点×20；25级：加权平均分×0.8',
    excellent_ratio DECIMAL(5,4) NOT NULL DEFAULT 0.20 COMMENT '优秀比例上限，按年级测评范围',
    a_cap DECIMAL(5,2) NOT NULL DEFAULT 20 COMMENT '基本素质A满分',
    b1_cap DECIMAL(5,2) NOT NULL DEFAULT 80 COMMENT '学业成绩B1满分',
    formula_note TEXT NOT NULL,
    effective_on DATE NOT NULL,
    parent_rule_id INT UNSIGNED NULL COMMENT '上一版本规则，NULL 表示该规则的第一个版本',
    UNIQUE (cohort, version_no),
    CHECK (excellent_ratio > 0 AND excellent_ratio <= 1
           AND a_cap > 0 AND b1_cap > 0 AND parent_rule_id <> rule_id),
    FOREIGN KEY (parent_rule_id) REFERENCES assessment_rule(rule_id)
) COMMENT='测评规则（按年级口径）';

CREATE TABLE academic_year (
    year_id VARCHAR(24) PRIMARY KEY,
    year_name VARCHAR(100) NOT NULL,
    starts_on DATE NOT NULL,
    ends_on DATE NOT NULL,
    opens_at DATETIME NOT NULL COMMENT 'UTC',
    deadline_at DATETIME NOT NULL COMMENT 'UTC，不含此刻',
    status ENUM('draft','open','review','published') NOT NULL DEFAULT 'draft',
    published_at DATETIME(6) NULL COMMENT 'UTC',
    CHECK (starts_on <= ends_on AND opens_at < deadline_at)
) COMMENT='学年（同一学年可同时套用多个年级口径规则）';

CREATE TABLE assessment_project (
    project_id INT UNSIGNED PRIMARY KEY,
    rule_id INT UNSIGNED NOT NULL,
    rule_key VARCHAR(32) NOT NULL COMMENT '规则匹配键：paper/book/project/competition/ip/social_work/volunteer/practice',
    -- component 由 rule_key 函数决定（rule_key→component 严格 1:1），属传递依赖。
    -- 改为 VIRTUAL 生成列：值由 rule_key 派生、不落盘，消除冗余以符合 3NF；
    -- 仍可查询并建索引（同 evidence.sha256 口径），上层 SQL 与网页无需改动。
    component VARCHAR(2) GENERATED ALWAYS AS
        (CASE WHEN rule_key IN ('social_work','volunteer','practice') THEN 'C' ELSE 'B2' END) VIRTUAL
        COMMENT '学术科研B2 / 实践能力C（由 rule_key 派生）',
    project_name VARCHAR(100) NOT NULL,
    -- category 是 component 的中文名（B2→学术科研，C→实践能力），由 rule_key 函数决定（rule_key→component→category），
    -- 属传递依赖。改为 VIRTUAL 生成列（与 component 同口径：派生不落盘、仍可查询），消除冗余以符合 3NF。
    category VARCHAR(80) GENERATED ALWAYS AS
        (CASE WHEN rule_key IN ('social_work','volunteer','practice') THEN '实践能力' ELSE '学术科研' END) VIRTUAL
        COMMENT '学术科研/实践能力（由 rule_key 派生）',
    score_cap DECIMAL(6,2) NOT NULL COMMENT '单项上限',
    total_cap DECIMAL(6,2) NULL COMMENT '同表单同项目累计上限，NULL 表示不设总上限',
    max_items INT UNSIGNED NULL COMMENT '同表单同项目最多申报条数，NULL 表示不限',
    evidence_required BOOLEAN NOT NULL DEFAULT FALSE,
    evidence_requirement VARCHAR(255) NULL,
    CHECK (score_cap > 0 AND (total_cap IS NULL OR total_cap > 0)
           AND (max_items IS NULL OR max_items > 0) AND evidence_required IN (0,1)),
    -- v13 N2：rule_key 是 component/category 两个生成列的唯一输入，必须限定在
    -- 已定义映射的 8 个键内；未列入的键会被 CASE ELSE 静默归为 B2/学术科研。
    CHECK (rule_key IN ('paper','book','project','competition','ip',
                        'social_work','volunteer','practice')),
    UNIQUE (rule_id, project_name),
    KEY (rule_id, component),
    FOREIGN KEY (rule_id) REFERENCES assessment_rule(rule_id)
) COMMENT='加分项目（B2/C）';

CREATE TABLE student_year_assessment (
    student_id VARCHAR(24) NOT NULL,
    year_id VARCHAR(24) NOT NULL,
    class_id VARCHAR(24) NOT NULL COMMENT '建档时的班级快照',
    rule_id INT UNSIGNED NOT NULL COMMENT '按入学年匹配的规则口径',
    a_score DECIMAL(5,2) NULL COMMENT '基本素质A最终分（0 至规则 a_cap，上限由 set_base_assessment 与触发器按规则校验）',
    b1_input DECIMAL(7,3) NULL COMMENT 'B1原始输入：24级为平均绩点，25级为加权平均分',
    a_failed BOOLEAN NOT NULL DEFAULT FALSE COMMENT '基本素质不合格（如纪律处分）',
    academic_failed BOOLEAN NOT NULL DEFAULT FALSE COMMENT '学业学术不合格（如两门必修不及格）',
    created_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    PRIMARY KEY (student_id, year_id),
    KEY (year_id, class_id),
    KEY (rule_id),
    CHECK (a_score IS NULL OR a_score >= 0),
    CHECK (b1_input IS NULL OR b1_input >= 0),
    CHECK (a_failed IN (0,1) AND academic_failed IN (0,1)),
    FOREIGN KEY (student_id) REFERENCES student(student_id),
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id),
    FOREIGN KEY (class_id) REFERENCES class_group(class_id),
    FOREIGN KEY (rule_id) REFERENCES assessment_rule(rule_id)
) COMMENT='学生学年测评（班级快照、规则、A/B1 基础分与不合格标记）';

CREATE TABLE application_form (
    form_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    student_id VARCHAR(24) NOT NULL,
    year_id VARCHAR(24) NOT NULL,
    notes TEXT NULL,
    submitted_at DATETIME(6) NULL,
    status ENUM('draft','submitted','completed','void') NOT NULL DEFAULT 'draft',
    modified_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    round_no INT UNSIGNED NOT NULL DEFAULT 0,
    UNIQUE (student_id, year_id),
    KEY (year_id, status),
    FOREIGN KEY (student_id, year_id) REFERENCES student_year_assessment(student_id, year_id),
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id)
) COMMENT='填报表';

-- 提交记录：学生每学年每一次提交的留痕（轮次、时间），
-- 仅由 submit_form 写入，此后不可修改，供追溯与审计。
CREATE TABLE submission_log (
    submission_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    form_id BIGINT UNSIGNED NOT NULL,
    round_no INT UNSIGNED NOT NULL,
    submitted_at DATETIME(6) NOT NULL,
    UNIQUE (form_id, round_no),
    FOREIGN KEY (form_id) REFERENCES application_form(form_id)
) COMMENT='提交记录（条目快照见 submission_snapshot_item）';

-- 提交时的条目快照：每次提交的每个条目一行，仅由 submit_form 写入，此后不可修改。
-- 不设 item_id 外键：快照必须独立于当前申报行保留（历史可追溯）。
CREATE TABLE submission_snapshot_item (
    submission_id BIGINT UNSIGNED NOT NULL,
    item_id BIGINT UNSIGNED NOT NULL,
    project_id INT UNSIGNED NOT NULL,
    details TEXT NOT NULL,
    claimed_score DECIMAL(10,2) NOT NULL,
    occurred_on DATE NOT NULL,
    PRIMARY KEY (submission_id, item_id),
    FOREIGN KEY (submission_id) REFERENCES submission_log(submission_id)
) COMMENT='提交时的条目快照';

CREATE TABLE application_item (
    item_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    form_id BIGINT UNSIGNED NOT NULL,
    project_id INT UNSIGNED NOT NULL,
    details TEXT NOT NULL,
    claimed_score DECIMAL(10,2) NOT NULL,
    occurred_on DATE NOT NULL,
    status ENUM('draft','initial_pending','counselor_pending','final_pending',
                'returned','approved','withdrawn') NOT NULL DEFAULT 'draft',
    final_score DECIMAL(10,2) NULL,
    CHECK (claimed_score >= 0 AND (final_score IS NULL OR final_score >= 0)),
    KEY (form_id, status),
    KEY (project_id, status),
    FOREIGN KEY (form_id) REFERENCES application_form(form_id),
    FOREIGN KEY (project_id) REFERENCES assessment_project(project_id)
) COMMENT='填报内容';

CREATE TABLE evidence (
    evidence_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    item_id BIGINT UNSIGNED NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    storage_location VARCHAR(120) NOT NULL UNIQUE COMMENT '库内对象标识',
    file_body MEDIUMBLOB NOT NULL,
    sha256 CHAR(64) CHARACTER SET ascii GENERATED ALWAYS AS (SHA2(file_body, 256)) VIRTUAL,
    uploaded_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (OCTET_LENGTH(file_body) BETWEEN 1 AND 5242880 AND active IN (0,1)),
    KEY (item_id, active),
    KEY (sha256),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id)
) COMMENT='证明材料（sha256 为 VIRTUAL 生成列并建索引：值由 file_body 派生、不落盘，查重走索引而非全表哈希）';

CREATE TABLE reviewer (
    reviewer_id INT UNSIGNED PRIMARY KEY,
    reviewer_name VARCHAR(80) NOT NULL,
    review_role ENUM('initial','counselor','final') NOT NULL,
    class_id VARCHAR(24) NULL COMMENT '初审必填，其他角色可选；空表示院系范围',
    login_name VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,
    CHECK (login_name REGEXP '^[A-Za-z0-9_]+$' AND (review_role <> 'initial' OR class_id IS NOT NULL)),
    FOREIGN KEY (class_id) REFERENCES class_group(class_id)
) COMMENT='审核人员';

CREATE TABLE review_record (
    review_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    item_id BIGINT UNSIGNED NOT NULL,
    reviewer_id INT UNSIGNED NOT NULL,
    stage ENUM('initial','counselor','final') NOT NULL,
    round_no INT UNSIGNED NOT NULL,
    reviewed_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    decision ENUM('pass','return') NOT NULL,
    opinion TEXT NULL,
    approved_score DECIMAL(10,2) NULL,
    UNIQUE (item_id, round_no, stage),
    CHECK (round_no > 0 AND
      ((stage = 'final' AND decision = 'pass' AND approved_score IS NOT NULL AND approved_score >= 0)
       OR ((stage <> 'final' OR decision <> 'pass') AND approved_score IS NULL))),
    KEY (reviewer_id, reviewed_at),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id),
    FOREIGN KEY (reviewer_id) REFERENCES reviewer(reviewer_id)
) COMMENT='审核记录（审核时看到的快照见 review_snapshot_item / review_snapshot_evidence）';

-- 审核时的申报快照：每次审核一行，记录审核人当时看到的项目、细节、申报分和日期。
-- 不设 project_id 外键：历史快照不随主数据变化。
CREATE TABLE review_snapshot_item (
    review_id BIGINT UNSIGNED PRIMARY KEY,
    project_id INT UNSIGNED NOT NULL,
    details TEXT NOT NULL,
    claimed_score DECIMAL(10,2) NOT NULL,
    occurred_on DATE NOT NULL,
    FOREIGN KEY (review_id) REFERENCES review_record(review_id)
) COMMENT='审核时的申报快照';

-- 审核时的附件编号快照：每次审核的每份有效附件一行，用于历史材料访问审计。
CREATE TABLE review_snapshot_evidence (
    review_id BIGINT UNSIGNED NOT NULL,
    evidence_id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (review_id, evidence_id),
    FOREIGN KEY (review_id) REFERENCES review_record(review_id)
) COMMENT='审核时的附件编号快照';

CREATE TABLE assessment_result (
    result_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    student_id VARCHAR(24) NOT NULL,
    year_id VARCHAR(24) NOT NULL,
    total_score DECIMAL(6,2) NOT NULL COMMENT 'A + B1 + B2 + C',
    UNIQUE (student_id, year_id),
    KEY (year_id),
    CHECK (total_score >= 0),
    FOREIGN KEY (student_id, year_id) REFERENCES student_year_assessment(student_id, year_id),
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id)
) COMMENT='测评总结果（等级见视图；排名见 assessment_ranking；批次时间见 academic_year.published_at）';

-- A/B1/B2/C 分项得分：公示时与总结果同事务落盘，作为冻结快照。
CREATE TABLE component_score (
    result_id BIGINT UNSIGNED NOT NULL,
    component ENUM('A','B1','B2','C') NOT NULL,
    score DECIMAL(6,2) NOT NULL,
    PRIMARY KEY (result_id, component),
    -- A/B1 上限随规则 a_cap/b1_cap 变化，CHECK 无法跨表取规则，故仅守非负；
    -- 满分上限由 check_component_cap_ins 触发器按规则校验（见下）。
    CHECK (score >= 0),
    FOREIGN KEY (result_id) REFERENCES assessment_result(result_id)
) COMMENT='A/B1/B2/C 分项得分';

-- 按年级的公示排名：真实细则以年级为测评范围，优秀比例也按年级控制。
-- grade_year 为入学年（不可变），已由 student 决定，属冗余传递依赖，故不落盘（3NF）；
-- 年级口径在 publish_year 排名时经 student 连接取得，展示层经 result_with_rank 连接取得。
CREATE TABLE assessment_ranking (
    year_id VARCHAR(24) NOT NULL,
    student_id VARCHAR(24) NOT NULL,
    rank_no INT UNSIGNED NOT NULL,
    PRIMARY KEY (year_id, student_id),
    KEY (year_id, rank_no),
    CHECK (rank_no > 0),
    FOREIGN KEY (student_id, year_id) REFERENCES assessment_result(student_id, year_id)
) COMMENT='按年级的公示排名（年级口径经 student 连接取得，不冗余落盘）';

-- AI/规则初审草稿：规则能直接算的记为 rule，AI 分类/折算的记为 ai/hybrid。
-- 只作审核参考，最终分数一律以 review_record 为准。
CREATE TABLE ai_review (
    ai_review_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    item_id BIGINT UNSIGNED NOT NULL,
    source ENUM('rule','ai','hybrid') NOT NULL,
    model VARCHAR(40) NOT NULL,
    prompt_version VARCHAR(20) NOT NULL,
    rule_key VARCHAR(32) NULL,
    subtype VARCHAR(40) NULL,
    author_rank SMALLINT UNSIGNED NULL,
    author_count SMALLINT UNSIGNED NULL,
    team_size SMALLINT UNSIGNED NULL,
    award_level VARCHAR(20) NULL,
    award_rank VARCHAR(20) NULL,
    hours DECIMAL(6,1) NULL,
    suggested_score DECIMAL(6,2) NOT NULL,
    confidence DECIMAL(4,3) NOT NULL,
    rationale TEXT NOT NULL,
    response_raw TEXT NULL,
    status ENUM('draft','accepted','overridden','ignored') NOT NULL DEFAULT 'draft',
    review_id BIGINT UNSIGNED NULL,
    created_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    decided_at DATETIME(6) NULL,
    CHECK (suggested_score >= 0 AND confidence BETWEEN 0 AND 1),
    KEY (item_id, created_at),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id),
    FOREIGN KEY (review_id) REFERENCES review_record(review_id)
) COMMENT='AI/规则初审草稿（仅参考，人工终审）';

-- 公示批次校验码：公示落盘时对该学年全部结果计算的 SHA-256 承诺，与学年 1:1。
-- 独立成表而非给 academic_year 加列：校验码是"公示批次"这一独立实体的属性，
-- 由结果数据与批次时刻决定，混入学年表会引入派生依赖、破坏 3NF 的清晰性；
-- 分表后还便于用授权实现不可变——任何角色都没有此表的写权限，落盘即不可篡改。
CREATE TABLE publication_batch (
    year_id VARCHAR(24) PRIMARY KEY,
    checksum CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id)
) COMMENT='公示批次校验码';

CREATE TABLE privacy_access_log (
    access_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    reviewer_id INT UNSIGNED NOT NULL,
    item_id BIGINT UNSIGNED NOT NULL,
    evidence_id BIGINT UNSIGNED NULL,
    accessed_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (reviewer_id, accessed_at),
    FOREIGN KEY (reviewer_id) REFERENCES reviewer(reviewer_id),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id),
    FOREIGN KEY (evidence_id) REFERENCES evidence(evidence_id)
) COMMENT='成功读取申报详情或附件的访问日志';

-- 越权访问尝试日志：失败也留痕。故意不设外键——审计写入绝不能因目标不存在而失败。
-- 由审核类过程的 EXIT HANDLER 在 ROLLBACK 之后补记（否则日志会随事务一起回滚）。
CREATE TABLE access_denied_log (
    denied_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    login_name VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    item_id BIGINT UNSIGNED NULL,
    evidence_id BIGINT UNSIGNED NULL,
    reason VARCHAR(100) NOT NULL,
    denied_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (login_name, denied_at)
) COMMENT='越权访问尝试日志';

-- 管理员操作与主数据变更审计：abandon_form/publish_year 过程内记录，
-- 6 张主数据表的 AFTER INSERT/UPDATE/DELETE 触发器记录数据变更（含学年状态 old→new）。
-- 故意不设外键，审计写入永不失败；被删除对象的历史记录仍可追溯。
CREATE TABLE admin_operation_log (
    op_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    operator_login VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    action VARCHAR(40) NOT NULL,
    target_id VARCHAR(64) NULL,
    detail VARCHAR(500) NULL,
    operated_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (operator_login, operated_at),
    KEY (action, operated_at)
) COMMENT='管理员操作与主数据变更审计';

-- 实体状态机变更日志：学年 / 表单 / 填报条目每一次状态迁移（old→new）单独留痕。
-- 与 admin_operation_log 分工：后者记录"管理员做了什么操作"（字段级主数据审计），
-- 本表记录"业务实体经历了怎样的生命周期"（状态机视角）。由 AFTER UPDATE 触发器自动写入，
-- 无论变更来自存储过程、网页接口、事件调度器还是管理员直改，一律捕获。故意不设外键。
CREATE TABLE status_change_log (
    change_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    entity_type ENUM('academic_year','application_form','application_item') NOT NULL,
    entity_id VARCHAR(64) NOT NULL,
    old_status VARCHAR(24) NOT NULL,
    new_status VARCHAR(24) NOT NULL,
    changed_by VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    changed_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (entity_type, entity_id, changed_at),
    KEY (changed_at)
) COMMENT='实体状态变更日志';

DELIMITER $$

-- 内部过程。角色没有调用权限。每个写操作按学年串行，避免提交、审核、公示交叉。
CREATE PROCEDURE lock_assessment_year(
    IN p_year VARCHAR(24), OUT p_status VARCHAR(16),
    OUT p_opens DATETIME, OUT p_deadline DATETIME
)
BEGIN
    SELECT status, opens_at, deadline_at INTO p_status, p_opens, p_deadline
    FROM academic_year WHERE year_id = p_year FOR UPDATE;
    IF p_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年不存在';
    END IF;
END$$

CREATE PROCEDURE lock_student_form(
    IN p_year VARCHAR(24), OUT p_student VARCHAR(24), OUT p_rule INT UNSIGNED,
    OUT p_form BIGINT UNSIGNED, OUT p_form_status VARCHAR(16)
)
BEGIN
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    DECLARE v_grade SMALLINT UNSIGNED;
    SET p_student = NULL, p_form = NULL, p_form_status = NULL, p_rule = NULL;
    SELECT s.student_id, s.grade_year INTO p_student, v_grade
    FROM student s WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1);
    IF p_student IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前数据库账号未绑定学生';
    END IF;
    SELECT a.rule_id INTO p_rule
    FROM student_year_assessment a
    WHERE a.student_id = p_student AND a.year_id = p_year;
    IF p_rule IS NULL THEN
        SELECT ar.rule_id INTO p_rule
        FROM assessment_rule ar
        WHERE ar.cohort = IF(v_grade <= 2024, 'le2024', 'ge2025')
          AND ar.effective_on <= UTC_DATE()
        ORDER BY ar.effective_on DESC, ar.rule_id DESC
        LIMIT 1;
    END IF;
    IF p_rule IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '没有匹配该年级的测评规则';
    END IF;
    CALL lock_assessment_year(p_year, v_status, v_opens, v_deadline);
    IF v_status <> 'open' OR UTC_TIMESTAMP() < v_opens OR UTC_TIMESTAMP() >= v_deadline THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前不在申报时间内';
    END IF;
    SELECT form_id, status INTO p_form, p_form_status
    FROM application_form WHERE student_id = p_student AND year_id = p_year FOR UPDATE;
END$$

CREATE PROCEDURE save_form(IN p_year VARCHAR(24), IN p_notes TEXT)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL THEN
        INSERT INTO student_year_assessment(student_id, year_id, class_id, rule_id)
        SELECT s.student_id, p_year, s.class_id, v_rule
        FROM student s
        WHERE s.student_id = v_student
          AND NOT EXISTS (SELECT 1 FROM student_year_assessment a
                          WHERE a.student_id = s.student_id AND a.year_id = p_year);
        INSERT INTO application_form(student_id, year_id, notes)
        VALUES(v_student, p_year, p_notes);
        SET v_form = LAST_INSERT_ID();
    ELSEIF v_status = 'draft' THEN
        UPDATE application_form SET notes = p_notes, modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请先撤回至草稿再修改表单';
    END IF;
    COMMIT;
    SELECT v_form AS form_id;
END$$

CREATE PROCEDURE reopen_form(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'submitted' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只有已提交表单可撤回';
    END IF;
    UPDATE application_item SET status = 'draft', final_score = NULL
    WHERE form_id = v_form AND status <> 'withdrawn';
    UPDATE application_form SET status = 'draft', modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
END$$

CREATE PROCEDURE save_item(
    IN p_year VARCHAR(24), IN p_item BIGINT UNSIGNED, IN p_project INT UNSIGNED,
    IN p_details TEXT, IN p_claim DECIMAL(10,2), IN p_date DATE
)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form, v_item BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请先建立或撤回本学年的草稿表单';
    END IF;
    IF p_details IS NULL OR CHAR_LENGTH(TRIM(p_details)) = 0 OR p_claim IS NULL OR p_claim < 0
       OR p_date IS NULL OR NOT EXISTS (
           SELECT 1 FROM academic_year WHERE year_id = p_year AND p_date BETWEEN starts_on AND ends_on
       ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '细节、申报分值或发生日期无效';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM assessment_project WHERE project_id = p_project AND rule_id = v_rule) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '项目不属于本学年规则';
    END IF;
    IF p_item IS NULL THEN
        INSERT INTO application_item(form_id, project_id, details, claimed_score, occurred_on)
        VALUES(v_form, p_project, p_details, p_claim, p_date);
        SET v_item = LAST_INSERT_ID();
    ELSE
        IF NOT EXISTS (SELECT 1 FROM application_item
                       WHERE item_id = p_item AND form_id = v_form AND status = 'draft') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '条目不在本人当前草稿内';
        END IF;
        UPDATE application_item
        SET project_id = p_project, details = p_details, claimed_score = p_claim, occurred_on = p_date
        WHERE item_id = p_item;
        SET v_item = p_item;
    END IF;
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
    SELECT v_item AS item_id;
END$$

CREATE PROCEDURE withdraw_item(IN p_year VARCHAR(24), IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM application_item WHERE item_id = p_item AND form_id = v_form AND status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能移除本人草稿内的条目';
    END IF;
    UPDATE application_item SET status = 'withdrawn' WHERE item_id = p_item;
    UPDATE evidence SET active = FALSE WHERE item_id = p_item;
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
END$$

CREATE PROCEDURE add_evidence(
    IN p_year VARCHAR(24), IN p_item BIGINT UNSIGNED, IN p_name VARCHAR(255), IN p_data MEDIUMBLOB
)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form, v_evidence BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM application_item WHERE item_id = p_item AND form_id = v_form AND status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能为本人草稿内的条目上传材料';
    END IF;
    IF p_name IS NULL OR CHAR_LENGTH(TRIM(p_name)) = 0 OR p_data IS NULL
       OR OCTET_LENGTH(p_data) NOT BETWEEN 1 AND 5242880 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '材料须有名称且大小介于 1 字节与 5 MiB';
    END IF;
    INSERT INTO evidence(item_id, file_name, storage_location, file_body)
    VALUES(p_item, p_name, CONCAT('db://evidence/', UUID()), p_data);
    SET v_evidence = LAST_INSERT_ID();
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
    SELECT v_evidence AS evidence_id;
END$$

CREATE PROCEDURE remove_evidence(IN p_year VARCHAR(24), IN p_evidence BIGINT UNSIGNED)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM evidence e JOIN application_item i USING (item_id)
        WHERE e.evidence_id = p_evidence AND e.active AND i.form_id = v_form AND i.status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能移除本人草稿内的有效材料';
    END IF;
    UPDATE evidence SET active = FALSE WHERE evidence_id = p_evidence;
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
END$$

CREATE PROCEDURE submit_form(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE v_submission BIGINT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能提交本人当前草稿';
    END IF;
    IF EXISTS (
        SELECT 1 FROM application_item i JOIN assessment_project p USING (project_id)
        WHERE i.form_id = v_form AND i.status = 'draft' AND p.evidence_required
        AND NOT EXISTS (SELECT 1 FROM evidence e WHERE e.item_id = i.item_id AND e.active)
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请补齐必需的证明材料';
    END IF;
    UPDATE application_item SET status = 'initial_pending' WHERE form_id = v_form AND status = 'draft';
    UPDATE application_form SET status = 'submitted', round_no = round_no + 1,
        submitted_at = UTC_TIMESTAMP(6), modified_at = UTC_TIMESTAMP(6)
    WHERE form_id = v_form;
    INSERT INTO submission_log(form_id, round_no, submitted_at)
    SELECT form_id, round_no, submitted_at FROM application_form WHERE form_id = v_form;
    SET v_submission = LAST_INSERT_ID();
    INSERT INTO submission_snapshot_item(submission_id, item_id, project_id, details, claimed_score, occurred_on)
    SELECT v_submission, item_id, project_id, details, claimed_score, occurred_on
    FROM application_item WHERE form_id = v_form AND status = 'initial_pending';
    COMMIT;
END$$


-- 审核账号只能处理自己负责的班级和阶段。会话身份从 MySQL 登录获取。
CREATE PROCEDURE lock_review_item(
    IN p_item BIGINT UNSIGNED, OUT p_reviewer INT UNSIGNED, OUT p_stage VARCHAR(16),
    OUT p_item_status VARCHAR(24), OUT p_round INT UNSIGNED, OUT p_year_status VARCHAR(16)
)
BEGIN
    DECLARE v_year, v_class, v_scope VARCHAR(24);
    DECLARE v_opens, v_deadline DATETIME;
    SET p_reviewer = NULL, v_year = NULL;
    SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
    SELECT reviewer_id, review_role, class_id INTO p_reviewer, p_stage, v_scope
    FROM reviewer WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
    SELECT f.year_id INTO v_year
    FROM application_item i JOIN application_form f USING (form_id) WHERE i.item_id = p_item;
    IF p_reviewer IS NULL OR v_year IS NULL THEN
        SET @sa_denial_item = p_item, @sa_denial_reason = '账号未绑定审核人或条目不存在';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权访问此申报条目';
    END IF;
    CALL lock_assessment_year(v_year, p_year_status, v_opens, v_deadline);
    SELECT a.class_id, i.status, f.round_no INTO v_class, p_item_status, p_round
    FROM application_item i JOIN application_form f USING (form_id)
    JOIN student_year_assessment a ON a.student_id = f.student_id AND a.year_id = f.year_id
    WHERE i.item_id = p_item FOR UPDATE;
    IF (v_scope IS NOT NULL AND v_scope <> v_class) OR p_round = 0 OR p_item_status = 'draft'
       OR (p_item_status = 'withdrawn' AND NOT EXISTS (
           SELECT 1 FROM review_record WHERE item_id = p_item
       )) THEN
        SET @sa_denial_item = p_item, @sa_denial_reason = '班级范围或条目状态不符';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权访问此申报条目';
    END IF;
END$$

CREATE PROCEDURE review_item(
    IN p_item BIGINT UNSIGNED, IN p_decision VARCHAR(12), IN p_opinion TEXT,
    IN p_final_score DECIMAL(10,2)
)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE v_claim DECIMAL(10,2);
    DECLARE v_item_cap DECIMAL(10,2);
    DECLARE v_total_cap DECIMAL(10,2);
    DECLARE v_sum DECIMAL(10,2);
    DECLARE v_locked BIGINT UNSIGNED;
    DECLARE v_review BIGINT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    IF v_year_status NOT IN ('open','review') OR v_item_status <> CONCAT(v_stage, '_pending') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前状态不能由该角色审核';
    END IF;
    IF p_decision IS NULL OR p_decision NOT IN ('pass','return')
       OR (p_decision = 'return' AND (p_opinion IS NULL OR CHAR_LENGTH(TRIM(p_opinion)) = 0)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请选择通过或驳回，驳回须填写意见';
    END IF;
    SELECT claimed_score INTO v_claim FROM application_item WHERE item_id = p_item;
    SELECT p.score_cap, p.total_cap INTO v_item_cap, v_total_cap
    FROM application_item i JOIN assessment_project p USING (project_id)
    WHERE i.item_id = p_item;
    IF v_stage = 'final' AND p_decision = 'pass' THEN
        IF p_final_score IS NULL OR p_final_score < 0 OR p_final_score > v_claim THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '终审核定分须介于零与申报分之间';
        END IF;
        IF p_final_score > v_item_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '终审核定分不能超过单项封顶分';
        END IF;
        -- 锁定同表单全部条目，串行化终审核定，防止并发终审绕过项目总上限校验
        SELECT MIN(item_id) INTO v_locked FROM application_item
        WHERE form_id = (SELECT form_id FROM application_item WHERE item_id = p_item)
        FOR UPDATE;
        -- 同表单同项目已通过条目的核定分合计 + 本次核定分不得超过项目总上限
        SELECT COALESCE(SUM(oi.final_score), 0) INTO v_sum
        FROM application_item oi
        WHERE oi.form_id = (SELECT form_id FROM application_item WHERE item_id = p_item)
          AND oi.project_id = (SELECT project_id FROM application_item WHERE item_id = p_item)
          AND oi.item_id <> p_item AND oi.status = 'approved';
        IF v_total_cap IS NOT NULL AND v_sum + p_final_score > v_total_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该项目核定分合计将超过总上限';
        END IF;
    ELSEIF p_final_score IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只有终审通过时填写核定分';
    END IF;
    INSERT INTO review_record(item_id, reviewer_id, stage, round_no, decision, opinion, approved_score)
    VALUES (p_item, v_reviewer, v_stage, v_round, p_decision, p_opinion, p_final_score);
    SET v_review = LAST_INSERT_ID();
    IF v_stage = 'final' AND p_decision = 'pass' THEN
        UPDATE ai_review ar
        JOIN (SELECT MAX(ai_review_id) AS id FROM ai_review WHERE item_id = p_item) x
          ON ar.ai_review_id = x.id
        SET ar.status = IF(ar.suggested_score = p_final_score, 'accepted', 'overridden'),
            ar.review_id = v_review, ar.decided_at = UTC_TIMESTAMP(6);
    END IF;
    INSERT INTO review_snapshot_item(review_id, project_id, details, claimed_score, occurred_on)
    SELECT v_review, project_id, details, claimed_score, occurred_on
    FROM application_item WHERE item_id = p_item;
    INSERT INTO review_snapshot_evidence(review_id, evidence_id)
    SELECT v_review, evidence_id FROM evidence WHERE item_id = p_item AND active;
    UPDATE application_item SET
        status = CASE WHEN p_decision = 'return' THEN 'returned'
                      WHEN v_stage = 'initial' THEN 'counselor_pending'
                      WHEN v_stage = 'counselor' THEN 'final_pending'
                      ELSE 'approved' END,
        final_score = p_final_score
    WHERE item_id = p_item;
    COMMIT;
END$$

CREATE PROCEDURE read_review_item(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT i.item_id, f.year_id, f.student_id, s.student_name, f.notes, p.project_name,
           i.details, i.claimed_score, i.occurred_on, i.status, f.round_no, i.final_score
    FROM application_item i JOIN application_form f USING (form_id)
    JOIN student s USING (student_id) JOIN assessment_project p USING (project_id)
    WHERE i.item_id = p_item;
    SELECT e.evidence_id, e.file_name, e.sha256, e.uploaded_at, e.active
    FROM evidence e
    WHERE e.item_id = p_item AND (e.active OR EXISTS (
        SELECT 1 FROM review_snapshot_evidence se
        JOIN review_record rr ON rr.review_id = se.review_id
        WHERE se.evidence_id = e.evidence_id AND rr.item_id = p_item
    )) ORDER BY e.evidence_id;
    SELECT review_id, reviewer_id, stage, round_no, reviewed_at, decision, opinion, approved_score
    FROM review_record WHERE item_id = p_item ORDER BY review_id;
    COMMIT;
END$$

CREATE PROCEDURE read_evidence(IN p_evidence BIGINT UNSIGNED)
BEGIN
    DECLARE v_item BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SELECT item_id INTO v_item FROM evidence WHERE evidence_id = p_evidence;
    CALL lock_review_item(v_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    IF NOT EXISTS (
        SELECT 1 FROM evidence e WHERE e.evidence_id = p_evidence AND (e.active OR EXISTS (
            SELECT 1 FROM review_snapshot_evidence se
            JOIN review_record r ON r.review_id = se.review_id
            WHERE se.evidence_id = p_evidence AND r.item_id = v_item
        ))
    ) THEN
        SET @sa_denial_item = v_item, @sa_denial_evidence = p_evidence, @sa_denial_reason = '无权访问此材料';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权访问此材料';
    END IF;
    INSERT INTO privacy_access_log(reviewer_id, item_id, evidence_id) VALUES(v_reviewer, v_item, p_evidence);
    SELECT evidence_id, file_name, sha256, file_body
    FROM evidence WHERE evidence_id = p_evidence;
    COMMIT;
END$$

-- 材料查重：审核人查看本条目每份附件在全库的重复情况（按 SHA-256 内容指纹）。
-- 只返回重复份数，不暴露其他学生的学号姓名——同一份证明被多人合法复用是存在的
-- （如集体活动证明），查重是提示而非拦截，是否采信仍由审核人判断。
CREATE PROCEDURE check_evidence_duplicates(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT e.evidence_id, e.file_name, e.sha256,
           (SELECT COUNT(*) FROM evidence d
            WHERE d.active AND d.sha256 = e.sha256) AS active_copies,
           (SELECT COUNT(*) FROM evidence d
            WHERE d.active AND d.item_id <> p_item
              AND d.sha256 = e.sha256) AS copies_on_other_items
    FROM evidence e
    WHERE e.item_id = p_item AND e.active
    ORDER BY e.evidence_id;
    COMMIT;
END$$

-- 驳回重提对比：把最近一次驳回时审核人看到的申报快照与学生修改后的当前条目
-- 并排返回，字段级标出是否变化，审核人无需重读全文即可定位改动。
CREATE PROCEDURE review_item_diff(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT
        rr.review_id, rr.round_no, rr.reviewed_at, rr.opinion,
        si.project_id AS project_then,
        i.project_id AS project_now,
        si.project_id <> i.project_id AS project_changed,
        si.details AS details_then,
        i.details AS details_now,
        si.details <> i.details AS details_changed,
        si.claimed_score AS claimed_then,
        i.claimed_score AS claimed_now,
        si.claimed_score <> i.claimed_score AS claimed_changed,
        CAST(si.occurred_on AS CHAR) AS occurred_then,
        CAST(i.occurred_on AS CHAR) AS occurred_now,
        si.occurred_on <> i.occurred_on AS occurred_changed,
        (SELECT COUNT(*) FROM review_snapshot_evidence se WHERE se.review_id = rr.review_id) AS evidence_count_then,
        (SELECT COUNT(*) FROM evidence e WHERE e.item_id = i.item_id AND e.active) AS evidence_count_now
    FROM review_record rr
    JOIN review_snapshot_item si ON si.review_id = rr.review_id
    JOIN application_item i ON i.item_id = rr.item_id
    WHERE rr.item_id = p_item AND rr.decision = 'return'
    ORDER BY rr.review_id DESC
    LIMIT 1;
    COMMIT;
END$$

-- 学生自查本人在各学年的成绩、排名及与上一学年的变化。
CREATE PROCEDURE my_progress()
READS SQL DATA
BEGIN
    SELECT p.year_id, p.year_name, p.total_score, p.rank_no, p.grade,
           p.prev_year_id, p.prev_total_score, p.prev_rank_no,
           p.score_delta, p.rank_improvement
    FROM student s JOIN student_progress p USING (student_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1)
    ORDER BY p.starts_on;
END$$

CREATE PROCEDURE review_queue(IN p_year VARCHAR(24), IN p_filter VARCHAR(16))
READS SQL DATA
BEGIN
    DECLARE v_role VARCHAR(16);
    DECLARE v_scope VARCHAR(24);
    IF p_filter IS NULL OR p_filter NOT IN ('pending','returned','completed','all') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '筛选值为 pending、returned、completed 或 all';
    END IF;
    -- 先解析调用者审核人身份与班级范围，再以常量等值过滤（避免 OR + IS NULL 迫使全表扫描）。
    SELECT review_role, class_id INTO v_role, v_scope
    FROM reviewer WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
    IF v_role IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前数据库账号未绑定审核人员';
    END IF;
    SELECT i.item_id, f.form_id, a.class_id, f.student_id, p.project_name,
           i.status, f.round_no, f.submitted_at
    FROM student_year_assessment a
    JOIN application_form f ON f.student_id = a.student_id AND f.year_id = a.year_id
    JOIN application_item i USING (form_id)
    JOIN assessment_project p USING (project_id)
    WHERE a.year_id = p_year
    AND (v_scope IS NULL OR a.class_id = v_scope)
    AND f.status <> 'void'
    AND i.status NOT IN ('draft','withdrawn')
    AND (p_filter = 'all' OR (p_filter = 'pending' AND i.status = CONCAT(v_role, '_pending'))
         OR (p_filter = 'returned' AND i.status = 'returned')
         OR (p_filter = 'completed' AND i.status = 'approved'))
    ORDER BY f.submitted_at, i.item_id;
END$$

CREATE PROCEDURE my_form_status(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT f.form_id, f.status, f.round_no, f.submitted_at, f.modified_at
    FROM student s JOIN application_form f USING (student_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year;
    SELECT i.item_id, i.project_id, i.status, i.final_score,
           r.round_no AS returned_in_round, r.opinion AS return_reason
    FROM student s JOIN application_form f USING (student_id)
    JOIN application_item i USING (form_id)
    LEFT JOIN review_record r ON r.review_id = (
        SELECT MAX(rr.review_id) FROM review_record rr
        WHERE rr.item_id = i.item_id AND rr.decision = 'return'
    )
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    ORDER BY i.item_id;
END$$

-- 学生查看本人上传的证明材料清单（仅元数据，不含文件内容）。
CREATE PROCEDURE my_evidence(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT i.item_id, i.project_id, e.evidence_id, e.file_name, e.sha256,
           e.uploaded_at, e.active
    FROM student s JOIN application_form f USING (student_id)
    JOIN application_item i USING (form_id)
    JOIN evidence e USING (item_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    ORDER BY i.item_id, e.evidence_id;
END$$

-- 学生查看本人各轮提交记录。
CREATE PROCEDURE my_submission_history(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT sl.submission_id, sl.round_no, sl.submitted_at,
           (SELECT COUNT(*) FROM submission_snapshot_item si
            WHERE si.submission_id = sl.submission_id) AS item_count
    FROM student s JOIN application_form f USING (student_id)
    JOIN submission_log sl USING (form_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    ORDER BY sl.submission_id;
END$$

-- 班级工作组/管理员录入 A 与 B1 基础分：不存在档案时自动建档（按入学年匹配规则）。
CREATE PROCEDURE set_base_assessment(
    IN p_year VARCHAR(24), IN p_student VARCHAR(24),
    IN p_a DECIMAL(5,2), IN p_b1_input DECIMAL(7,3),
    IN p_a_failed BOOLEAN, IN p_academic_failed BOOLEAN
)
BEGIN
    DECLARE v_class VARCHAR(24);
    DECLARE v_grade SMALLINT UNSIGNED;
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_formula VARCHAR(16);
    DECLARE v_a_cap, v_b1_cap DECIMAL(5,2);
    DECLARE v_b1 DECIMAL(10,4);
    DECLARE v_role VARCHAR(16);
    DECLARE v_scope VARCHAR(24);
    DECLARE v_year_status VARCHAR(16);
    DECLARE v_admin INT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SELECT class_id, grade_year INTO v_class, v_grade
    FROM student WHERE student_id = p_student;
    IF v_class IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学生不存在';
    END IF;
    -- 学年状态守卫：学年须存在，且已公示后基础分冻结，不可再改（与公示校验码口径一致）。
    SELECT status INTO v_year_status FROM academic_year WHERE year_id = p_year;
    IF v_year_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年不存在';
    END IF;
    IF v_year_status = 'published' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年已公示，不可修改基础分';
    END IF;
    -- 规则版本稳定：已建档则沿用建档时锁定的规则版本，不随后续规则更新漂移；
    -- 仅未建档时才按入学年匹配当前最新规则，保证同一档案全程用同一口径计算。
    SELECT rule_id INTO v_rule FROM student_year_assessment
    WHERE student_id = p_student AND year_id = p_year;
    IF v_rule IS NULL THEN
        SELECT rule_id INTO v_rule FROM assessment_rule
        WHERE cohort = IF(v_grade <= 2024, 'le2024', 'ge2025')
          AND effective_on <= UTC_DATE()
        ORDER BY effective_on DESC, rule_id DESC LIMIT 1;
        IF v_rule IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '没有匹配该年级的测评规则';
        END IF;
    END IF;
    INSERT INTO student_year_assessment(student_id, year_id, class_id, rule_id)
    VALUES (p_student, p_year, v_class, v_rule)
    ON DUPLICATE KEY UPDATE rule_id = rule_id;
    SELECT b1_formula, a_cap, b1_cap INTO v_formula, v_a_cap, v_b1_cap
    FROM assessment_rule WHERE rule_id = v_rule;
    IF CURRENT_ROLE() LIKE '%sa_admin%' THEN SET v_admin = 1; END IF;
    IF v_admin = 0 THEN
        SELECT review_role, class_id INTO v_role, v_scope
        FROM reviewer WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
        IF v_role IS NULL OR v_role <> 'initial'
           OR (v_scope IS NOT NULL AND v_scope <> v_class) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权录入该班级基础分';
        END IF;
    END IF;
    IF p_a IS NULL OR p_a NOT BETWEEN 0 AND v_a_cap THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '基本素质A须在0与规则满分之间';
    END IF;
    IF p_b1_input IS NULL OR p_b1_input < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'B1原始分无效';
    END IF;
    SET v_b1 = IF(v_formula = 'gpa_x20', p_b1_input * 20, p_b1_input * 0.8);
    IF v_b1 > v_b1_cap THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'B1换算后超过规则满分';
    END IF;
    UPDATE student_year_assessment
    SET a_score = p_a, b1_input = p_b1_input,
        a_failed = COALESCE(p_a_failed, FALSE),
        academic_failed = COALESCE(p_academic_failed, FALSE)
    WHERE student_id = p_student AND year_id = p_year;
    COMMIT;
END$$

-- 班级初审员查看本班学生的基础分状态。
CREATE PROCEDURE web_base_scores(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_role VARCHAR(16);
    DECLARE v_scope VARCHAR(24);
    SELECT review_role, class_id INTO v_role, v_scope
    FROM reviewer WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
    IF v_role <> 'initial' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只有班级初审员可查看基础分录入页';
    END IF;
    SELECT s.student_id, s.student_name, s.class_id, s.grade_year,
           a.a_score, a.b1_input, a.a_failed, a.academic_failed,
           ar.b1_formula,
           CASE WHEN ar.b1_formula = 'gpa_x20' THEN '平均绩点'
                WHEN ar.b1_formula = 'weighted_x08' THEN '加权平均分'
                ELSE '未建档' END AS b1_label
    FROM student s
    LEFT JOIN student_year_assessment a
      ON a.student_id = s.student_id AND a.year_id = p_year
    LEFT JOIN assessment_rule ar ON ar.rule_id = a.rule_id
    WHERE (v_scope IS NULL OR s.class_id = v_scope)
    ORDER BY s.student_id;
END$$

-- 学生取本人本学年可申报的 B2/C 加分项目（无档案时按入学年取默认规则）。
CREATE PROCEDURE web_projects(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_grade SMALLINT UNSIGNED;
    DECLARE v_rule INT UNSIGNED;
    SELECT student_id, grade_year INTO v_student, v_grade
    FROM student WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
    SELECT rule_id INTO v_rule FROM student_year_assessment
    WHERE student_id = v_student AND year_id = p_year;
    IF v_rule IS NULL THEN
        SELECT rule_id INTO v_rule FROM assessment_rule
        WHERE cohort = IF(v_grade <= 2024, 'le2024', 'ge2025')
          AND effective_on <= UTC_DATE()
        ORDER BY effective_on DESC, rule_id DESC LIMIT 1;
    END IF;
    SELECT p.project_id, p.component, p.rule_key, p.project_name, p.category,
           p.score_cap, p.total_cap, p.max_items, p.evidence_required, p.evidence_requirement
    FROM assessment_project p
    WHERE p.rule_id = v_rule
    ORDER BY FIELD(p.component, 'B2', 'C'), p.project_id;
END$$

-- AI 初审上下文：只给审核范围内的人看，并记一条隐私访问日志。
CREATE PROCEDURE web_ai_context(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SET SESSION group_concat_max_len = 65535;
    SELECT i.item_id, f.year_id, f.student_id, s.student_name, sya.class_id,
           p.project_id, p.project_name, p.component, p.rule_key, p.score_cap, p.total_cap,
           i.details, i.claimed_score, i.occurred_on, i.status, i.final_score, f.round_no,
           (SELECT GROUP_CONCAT(e.file_name ORDER BY e.evidence_id SEPARATOR '、')
            FROM evidence e WHERE e.item_id = i.item_id AND e.active) AS evidence_names,
           ar.cohort, ar.b1_formula
    FROM application_item i
    JOIN application_form f USING (form_id)
    JOIN student s USING (student_id)
    JOIN student_year_assessment sya ON sya.student_id = f.student_id AND sya.year_id = f.year_id
    JOIN assessment_project p USING (project_id)
    JOIN assessment_rule ar ON ar.rule_id = sya.rule_id
    WHERE i.item_id = p_item;
    COMMIT;
END$$

CREATE PROCEDURE web_ai_draft(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT ai_review_id, source, model, prompt_version, rule_key, subtype,
           author_rank, author_count, team_size, award_level, award_rank, hours,
           suggested_score, confidence, rationale, status, created_at, decided_at
    FROM ai_review WHERE item_id = p_item ORDER BY ai_review_id DESC LIMIT 1;
    COMMIT;
END$$

CREATE PROCEDURE web_save_ai_draft(
    IN p_item BIGINT UNSIGNED, IN p_source VARCHAR(8), IN p_model VARCHAR(40),
    IN p_prompt_version VARCHAR(20), IN p_rule_key VARCHAR(32), IN p_subtype VARCHAR(40),
    IN p_author_rank SMALLINT UNSIGNED, IN p_author_count SMALLINT UNSIGNED,
    IN p_team_size SMALLINT UNSIGNED, IN p_award_level VARCHAR(20), IN p_award_rank VARCHAR(20),
    IN p_hours DECIMAL(6,1), IN p_score DECIMAL(6,2), IN p_confidence DECIMAL(4,3),
    IN p_rationale TEXT, IN p_raw TEXT
)
BEGIN
    DECLARE v_cap DECIMAL(6,2);
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT p.score_cap INTO v_cap
    FROM application_item i JOIN assessment_project p USING (project_id)
    WHERE i.item_id = p_item;
    IF v_cap IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报条目不存在';
    END IF;
    SET p_score = GREATEST(0, LEAST(COALESCE(p_score, 0), v_cap));
    SET p_confidence = GREATEST(0, LEAST(COALESCE(p_confidence, 0), 1));
    INSERT INTO ai_review(item_id, source, model, prompt_version, rule_key, subtype,
                          author_rank, author_count, team_size, award_level, award_rank, hours,
                          suggested_score, confidence, rationale, response_raw)
    VALUES (p_item, p_source, p_model, p_prompt_version, p_rule_key, p_subtype,
            p_author_rank, p_author_count, p_team_size, p_award_level, p_award_rank, p_hours,
            p_score, p_confidence, COALESCE(p_rationale, ''), p_raw);
    SELECT LAST_INSERT_ID() AS ai_review_id, p_score AS suggested_score;
    COMMIT;
END$$

DELIMITER ;

-- 真实口径计算输入：A + B1 + B2 + C。
-- A/B1 来自班级工作组/教务录入；B2/C 来自已终审通过的加分条目。
CREATE VIEW calculation_input AS
SELECT a.student_id, a.year_id, a.rule_id,
       a.a_score, a.b1_input,
       CASE ar.b1_formula
            WHEN 'gpa_x20' THEN a.b1_input * 20
            ELSE a.b1_input * 0.8
       END AS b1_score,
       COALESCE(SUM(CASE WHEN p.component = 'B2' THEN i.final_score END), 0) AS b2_score,
       COALESCE(SUM(CASE WHEN p.component = 'C' THEN i.final_score END), 0) AS c_score,
       a.a_failed, a.academic_failed
FROM student_year_assessment a
JOIN assessment_rule ar ON ar.rule_id = a.rule_id
LEFT JOIN application_form f ON f.student_id = a.student_id AND f.year_id = a.year_id
                             AND f.status IN ('submitted','completed')
LEFT JOIN application_item i ON i.form_id = f.form_id AND i.status = 'approved'
LEFT JOIN assessment_project p ON p.project_id = i.project_id AND p.rule_id = a.rule_id
GROUP BY a.student_id, a.year_id, a.rule_id, a.a_score, a.b1_input, ar.b1_formula,
         a.a_failed, a.academic_failed;

DELIMITER $$

-- 内部过程：对某学年公示批次的全部结果计算 SHA-256 摘要。
-- 摘要覆盖 学年|批次时刻|每个学生的(学号:总分:名次:入学年:班级:A不合格:学业不合格:优秀比例:各组件(组件:分))。
-- 除冻结的total_score/rank_no/组件分，还纳入等级评定输入(grade_year/a_failed/academic_failed/excellent_ratio)，
-- 因为 grade 在 result_with_rank 中按这些输入实时重算；任何一处事后改动都会使 verify_publication 重算结果与落盘校验码不一致。
-- v13 S5：再纳入 a.class_id —— 实名公示 public_notice 与匿名 published_results 都按班级展示，
-- 公示后改班级快照会改变公示内容，因此也必须破坏校验码（与 grade_year 同口径）。
CREATE PROCEDURE calc_publication_digest(
    IN p_year VARCHAR(24), IN p_batch DATETIME(6), OUT p_digest CHAR(64)
)
READS SQL DATA
BEGIN
    SET SESSION group_concat_max_len = 1048576;
    SET p_digest = SHA2(CONCAT(
        p_year, '|', p_batch, '|',
        COALESCE((
            SELECT GROUP_CONCAT(
                CONCAT(r.student_id, ':', r.total_score, ':', rk.rank_no, ':',
                       s.grade_year, ':', a.class_id, ':',
                       a.a_failed, ':', a.academic_failed, ':', ar.excellent_ratio, ':',
                       COALESCE((SELECT GROUP_CONCAT(
                                    CONCAT(cs.component, ':', cs.score)
                                    ORDER BY FIELD(cs.component, 'A','B1','B2','C') SEPARATOR ',')
                                 FROM component_score cs WHERE cs.result_id = r.result_id), ''))
                ORDER BY r.student_id SEPARATOR ';')
            FROM assessment_result r
            JOIN assessment_ranking rk
              ON rk.year_id = r.year_id AND rk.student_id = r.student_id
            JOIN student s ON s.student_id = r.student_id
            JOIN student_year_assessment a
              ON a.student_id = r.student_id AND a.year_id = r.year_id
            JOIN assessment_rule ar ON ar.rule_id = a.rule_id
            WHERE r.year_id = p_year
        ), '')
    ), 256);
END$$

CREATE PROCEDURE publish_year(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    DECLARE v_batch DATETIME(6);
    DECLARE v_checksum CHAR(64);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_assessment_year(p_year, v_status, v_opens, v_deadline);
    IF v_status NOT IN ('open','review') OR UTC_TIMESTAMP() < v_deadline THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '仅在申报截止后且学年尚未公示时发布';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM student_year_assessment WHERE year_id = p_year) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '没有可发布的测评档案';
    END IF;
    IF EXISTS (
        SELECT 1 FROM application_form f JOIN application_item i USING (form_id)
        WHERE f.year_id = p_year AND f.status = 'submitted'
        AND i.status NOT IN ('approved','withdrawn')
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '存在尚未通过终审的已提交表单';
    END IF;
    IF EXISTS (SELECT 1 FROM calculation_input
               WHERE year_id = p_year AND (a_score IS NULL OR b1_input IS NULL)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '存在尚未录入 A/B1 基础分的测评档案（未提交者请先录入或作废）';
    END IF;
    IF EXISTS (
        SELECT 1 FROM calculation_input c JOIN assessment_rule ar ON ar.rule_id = c.rule_id
        WHERE c.year_id = p_year AND (c.a_score > ar.a_cap OR c.b1_score > ar.b1_cap)
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A/B1 超过规则满分，请检查基础分或绩点/加权平均分';
    END IF;
    SET v_batch = UTC_TIMESTAMP(6);
    INSERT INTO assessment_result(student_id, year_id, total_score)
    SELECT student_id, year_id,
           ROUND(COALESCE(a_score, 0) + COALESCE(b1_score, 0) + b2_score + c_score, 2)
    FROM calculation_input WHERE year_id = p_year;
    INSERT INTO component_score(result_id, component, score)
    SELECT r.result_id, 'A', c.a_score
    FROM assessment_result r JOIN calculation_input c USING (student_id, year_id)
    WHERE c.year_id = p_year
    UNION ALL
    SELECT r.result_id, 'B1', c.b1_score
    FROM assessment_result r JOIN calculation_input c USING (student_id, year_id)
    WHERE c.year_id = p_year
    UNION ALL
    SELECT r.result_id, 'B2', c.b2_score
    FROM assessment_result r JOIN calculation_input c USING (student_id, year_id)
    WHERE c.year_id = p_year
    UNION ALL
    SELECT r.result_id, 'C', c.c_score
    FROM assessment_result r JOIN calculation_input c USING (student_id, year_id)
    WHERE c.year_id = p_year;
    -- 按年级排名；同分并列且名次连续（DENSE_RANK，1,1,2），优秀配额在视图中按年级人数 × excellent_ratio 计算。
    -- 年级口径经 student 连接取得用于分区，不落盘 grade_year（3NF：入学年已由 student 决定）。
    INSERT INTO assessment_ranking(year_id, student_id, rank_no)
    SELECT r.year_id, r.student_id,
           CAST(DENSE_RANK() OVER (PARTITION BY r.year_id, s.grade_year
                                   ORDER BY r.total_score DESC) AS UNSIGNED)
    FROM assessment_result r JOIN student s USING (student_id)
    WHERE r.year_id = p_year;
    -- 对本批次全部结果计算校验码并同事务落盘，与结果原子提交
    CALL calc_publication_digest(p_year, v_batch, v_checksum);
    INSERT INTO publication_batch(year_id, checksum) VALUES (p_year, v_checksum);
    UPDATE application_form SET status = 'completed' WHERE year_id = p_year AND status = 'submitted';
    UPDATE academic_year SET status = 'published', published_at = v_batch WHERE year_id = p_year;
    INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
    VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'publish_year', p_year, CONCAT('batch=', v_batch));
    COMMIT;
END$$

-- 管理员兜底：申报截止后（UTC_TIMESTAMP() >= deadline_at）且学年尚未公示时，
-- 可把未完成的表单作废（status → void，未通过条目撤回），避免个别学生卡死整学年公示。
-- 是否作废、是否公示一律以截止时间为依据：截止前学生仍有申报机会，不可提前作废。
CREATE PROCEDURE abandon_form(IN p_year VARCHAR(24), IN p_student VARCHAR(24))
BEGIN
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    DECLARE v_form BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_form_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_assessment_year(p_year, v_status, v_opens, v_deadline);
    IF v_status IN ('draft','published') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '草稿或已公示学年不可作废表单';
    END IF;
    IF UTC_TIMESTAMP() < v_deadline THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报截止前不可作废表单';
    END IF;
    SELECT form_id, status INTO v_form, v_form_status
    FROM application_form WHERE student_id = p_student AND year_id = p_year FOR UPDATE;
    IF v_form IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该学生本学年没有表单';
    END IF;
    IF v_form_status IN ('void','completed') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '表单已作废或已随学年公示';
    END IF;
    UPDATE application_item SET status = 'withdrawn'
    WHERE form_id = v_form AND status NOT IN ('approved','withdrawn');
    UPDATE application_form SET status = 'void', modified_at = UTC_TIMESTAMP(6)
    WHERE form_id = v_form;
    -- 作废即放弃本学年：若基础分尚未录入则记 0，避免空分档案阻塞整学年公示（班级工作组仍可后续补录）。
    UPDATE student_year_assessment SET a_score = COALESCE(a_score, 0), b1_input = COALESCE(b1_input, 0)
    WHERE student_id = p_student AND year_id = p_year;
    INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
    VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'abandon_form', p_year,
            CONCAT('student=', p_student, ', form=', v_form));
    COMMIT;
    SELECT v_form AS form_id, 'void' AS new_status;
END$$

CREATE PROCEDURE my_result(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT r.result_id, y.year_name, a.class_id, r.total_score, pr.grade,
           rk.rank_no, y.published_at AS generated_at
    FROM student s JOIN assessment_result r USING (student_id)
    JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
    JOIN academic_year y ON y.year_id = r.year_id
    JOIN assessment_ranking rk ON rk.year_id = r.year_id AND rk.student_id = r.student_id
    JOIN published_results pr ON pr.result_id = r.result_id
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1)
      AND y.year_id = p_year AND y.status = 'published';
    SELECT cs.component,
           CASE cs.component WHEN 'A' THEN '基本素质'
                             WHEN 'B1' THEN '学业成绩'
                             WHEN 'B2' THEN '学术科研'
                             ELSE '实践能力' END AS component_name,
           cs.score
    FROM student s JOIN assessment_result r USING (student_id)
    JOIN academic_year y USING (year_id)
    JOIN component_score cs USING (result_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1)
      AND y.year_id = p_year AND y.status = 'published'
    ORDER BY FIELD(cs.component, 'A','B1','B2','C');
END$$

-- 公示校验：任何角色可调用。重算当前结果的摘要并与公示时落盘的校验码比对，
-- intact=1 表示公示数据自发布以来未被改动，=0 表示存在事后篡改（或数据损坏）。
-- 威胁模型：检测绕过应用层的局部改动（如直接 UPDATE 某学生总分）；root 全库重算不在此列。
CREATE PROCEDURE verify_publication(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    DECLARE v_status VARCHAR(16);
    DECLARE v_batch DATETIME(6);
    DECLARE v_stored CHAR(64);
    DECLARE v_recomputed CHAR(64);
    SELECT status, published_at INTO v_status, v_batch
    FROM academic_year WHERE year_id = p_year;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年不存在';
    END IF;
    IF v_status <> 'published' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该学年尚未公示';
    END IF;
    SELECT checksum INTO v_stored FROM publication_batch WHERE year_id = p_year;
    CALL calc_publication_digest(p_year, v_batch, v_recomputed);
    SELECT p_year AS year_id, v_batch AS published_at, v_stored AS stored_checksum,
           v_recomputed AS recomputed_checksum, (v_stored = v_recomputed) AS intact;
END$$

DELIMITER ;

CREATE VIEW available_projects AS
SELECT p.rule_id, ar.cohort, p.project_id, p.component, p.rule_key,
       p.project_name, p.category, p.score_cap, p.total_cap, p.max_items,
       p.evidence_required, p.evidence_requirement
FROM assessment_project p JOIN assessment_rule ar USING (rule_id);

-- 公示结果中间视图（内部、含个人标识，不直接授权）：统一计算年级内名次、年级人数、
-- 不合格标记与等级 grade，供 published_results（匿名）与 public_notice（实名）分别投影。
-- 优秀评选：不合格学生不占优秀名额——合格学生在本年级"合格组"内单独 DENSE_RANK 竞争名额，
-- 名额分母仍按年级总人数 FLOOR(总人数×优秀比例)（与细则"按年级 20%"一致）；
-- 展示名次 rank_no 仍取全年级 DENSE_RANK（含不合格），保持并列与连续名次口径不变。
CREATE VIEW result_with_rank AS
SELECT r.result_id, r.year_id, y.year_name, r.student_id, s.grade_year, a.class_id, a.rule_id,
       r.total_score, rk.rank_no,
       COUNT(*) OVER (PARTITION BY r.year_id, s.grade_year) AS grade_count,
       ar.excellent_ratio, a.a_failed, a.academic_failed, y.published_at,
       CASE WHEN a.a_failed OR a.academic_failed THEN '不合格'
            WHEN DENSE_RANK() OVER (PARTITION BY r.year_id, s.grade_year, (a.a_failed OR a.academic_failed)
                                    ORDER BY r.total_score DESC)
                 <= FLOOR(COUNT(*) OVER (PARTITION BY r.year_id, s.grade_year) * ar.excellent_ratio) THEN '优秀'
            ELSE '合格' END AS grade
FROM assessment_result r
JOIN academic_year y USING (year_id)
JOIN student s USING (student_id)
JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
JOIN assessment_rule ar ON ar.rule_id = a.rule_id
JOIN assessment_ranking rk ON rk.year_id = r.year_id AND rk.student_id = r.student_id
WHERE y.status = 'published';

-- 匿名公示口径：不含学号/姓名/规则号，仅编号、学年、班级、年级、总分、等级、名次，
-- 授予 sa_analyst 做统计分析；面向学生的实名公示走 public_notice。
CREATE VIEW published_results AS
SELECT rr.result_id, rr.year_id, rr.year_name, rr.class_id, rr.grade_year,
       rr.total_score, rr.grade, rr.rank_no, rr.published_at AS generated_at
FROM result_with_rank rr;

-- 结果公示视图：仅学年状态为 published 后可见，含学号姓名，供学生和统计角色查看。
CREATE VIEW public_notice AS
SELECT rr.year_id, rr.year_name, rr.class_id, c.class_name, rr.student_id, s.student_name,
       rr.grade_year, rr.total_score, rr.grade, rr.rank_no, rr.published_at AS generated_at
FROM result_with_rank rr
JOIN student s USING (student_id)
JOIN class_group c ON c.class_id = rr.class_id;

-- 隐私口径说明：小班级的 MIN/MAX/AVG 在人数极少时可反推个人分数。
-- 本视图仅授予受信内部角色 sa_analyst（不对外）；面向学生的公示走 public_notice。
-- 如需彻底防反推可加 HAVING COUNT(*) >= k，但会改变演示数据的输出口径，故未启用。
CREATE VIEW class_result_distribution AS
SELECT r.year_id, r.class_id, c.class_name, r.grade, COUNT(*) AS student_count,
       MIN(r.total_score) AS minimum_score, MAX(r.total_score) AS maximum_score,
       ROUND(AVG(r.total_score), 2) AS average_score
FROM published_results r JOIN class_group c USING (class_id)
GROUP BY r.year_id, r.class_id, c.class_name, r.grade;

CREATE VIEW project_submission_statistics AS
SELECT f.year_id, p.project_id, p.project_name, COUNT(*) AS submitted_items,
       SUM(i.status = 'approved') AS approved_items, SUM(i.status = 'returned') AS returned_items
FROM application_form f JOIN application_item i USING (form_id)
JOIN assessment_project p USING (project_id)
WHERE f.status IN ('submitted','completed') AND i.status <> 'withdrawn'
GROUP BY f.year_id, p.project_id, p.project_name;

-- 跨学年个人进展：用 LAG 窗口函数取学生上一次参加测评的学年、总分与名次，
-- 计算分数变化（score_delta）与名次进步（rank_improvement，正数表示名次上升）。
-- 含规则版本提示（rule_id/version_no）：规则版本不同的学年分数可比性有限，读数据时自行判断。
-- 含个人标识，仅作内部视图（SQL SECURITY DEFINER），不直接授予任何角色。
CREATE VIEW student_progress AS
SELECT pr.student_id, pr.year_id, y.year_name, y.starts_on, pr.class_id,
       pr.rule_id, ar.version_no,
       pr.total_score, pr.rank_no, pr.grade,
       LAG(pr.year_id) OVER w AS prev_year_id,
       LAG(pr.total_score) OVER w AS prev_total_score,
       LAG(pr.rank_no) OVER w AS prev_rank_no,
       ROUND(pr.total_score - LAG(pr.total_score) OVER w, 2) AS score_delta,
       CAST(LAG(pr.rank_no) OVER w AS SIGNED) - CAST(pr.rank_no AS SIGNED) AS rank_improvement
FROM result_with_rank pr
JOIN academic_year y USING (year_id)
JOIN assessment_rule ar ON ar.rule_id = pr.rule_id
WINDOW w AS (PARTITION BY pr.student_id ORDER BY y.starts_on);

-- 班级层面的跨学年进步统计（仅聚合值，不含个人标识），供统计分析员使用。
CREATE VIEW class_progress_stats AS
SELECT year_id, year_name, class_id, COUNT(*) AS student_count,
       SUM(rank_improvement > 0) AS improved_count,
       SUM(rank_improvement < 0) AS declined_count,
       SUM(rank_improvement = 0) AS unchanged_count,
       ROUND(AVG(score_delta), 2) AS avg_score_delta
FROM student_progress
WHERE prev_year_id IS NOT NULL
GROUP BY year_id, year_name, class_id;

-- 运维监控视图：截止后仍卡住的已提交表单（存在未终审条目，或没有任何条目通过终审），
-- 供管理员定位需要 abandon_form 处理的学生，避免个别表单卡死整学年公示。
CREATE VIEW admin_stalled_forms AS
SELECT f.year_id, f.student_id, s.student_name, a.class_id, f.form_id, f.round_no, f.submitted_at,
       SUM(i.status NOT IN ('approved','withdrawn')) AS blocking_items,
       SUM(i.status = 'approved') AS approved_items
FROM application_form f
JOIN academic_year y ON y.year_id = f.year_id
JOIN student s ON s.student_id = f.student_id
JOIN student_year_assessment a ON a.student_id = f.student_id AND a.year_id = f.year_id
JOIN application_item i ON i.form_id = f.form_id
WHERE f.status = 'submitted' AND y.status IN ('open','review')
  AND UTC_TIMESTAMP() >= y.deadline_at
GROUP BY f.year_id, f.student_id, s.student_name, a.class_id, f.form_id, f.round_no, f.submitted_at
HAVING blocking_items > 0 OR approved_items = 0;

-- 规则版本链：从每个首版规则（parent_rule_id IS NULL）沿 parent_rule_id 递归展开，
-- 给出根版本、链深与路径。纯链条结构，不附带使用统计，保持视图轻量。
-- 深度上限 50 为防御性边界；成环数据因无根不可达，本就不会进入递归。
CREATE VIEW rule_version_chain AS
WITH RECURSIVE chain AS (
    SELECT rule_id AS root_rule_id, rule_id, rule_name, version_no, parent_rule_id,
           effective_on, 1 AS depth, CAST(rule_id AS CHAR(1000)) AS version_path
    FROM assessment_rule
    WHERE parent_rule_id IS NULL
    UNION ALL
    SELECT c.root_rule_id, r.rule_id, r.rule_name, r.version_no, r.parent_rule_id,
           r.effective_on, c.depth + 1, CONCAT(c.version_path, '->', r.rule_id)
    FROM assessment_rule r JOIN chain c ON r.parent_rule_id = c.rule_id
    WHERE c.depth < 50
)
SELECT rule_id, rule_name, version_no, parent_rule_id, effective_on,
       root_rule_id, depth, version_path
FROM chain;

-- 管理员全局查重视图：内容指纹相同且出现多份的附件分组（含停用件，供追溯）。
-- 仅编号与计数，不含文件内容；管理员本就只有元数据列权限。
CREATE VIEW evidence_duplicates AS
SELECT sha256, COUNT(*) AS total_copies,
       SUM(active) AS active_copies,
       COUNT(DISTINCT item_id) AS distinct_items,
       GROUP_CONCAT(evidence_id ORDER BY evidence_id) AS evidence_ids
FROM evidence
GROUP BY sha256
HAVING COUNT(*) > 1;

CREATE ROLE IF NOT EXISTS 'sa_student', 'sa_reviewer', 'sa_analyst', 'sa_publisher', 'sa_admin';
GRANT SELECT ON student_assessment.available_projects TO 'sa_student', 'sa_reviewer';
GRANT SELECT ON student_assessment.published_results TO 'sa_analyst';
GRANT SELECT ON student_assessment.class_result_distribution TO 'sa_analyst';
GRANT SELECT ON student_assessment.project_submission_statistics TO 'sa_analyst';
GRANT SELECT ON student_assessment.class_progress_stats TO 'sa_analyst';
GRANT EXECUTE ON PROCEDURE student_assessment.save_form TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.reopen_form TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.save_item TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.withdraw_item TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.add_evidence TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.remove_evidence TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.submit_form TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_form_status TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_result TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_progress TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.review_queue TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.review_item TO 'sa_reviewer';
-- 读类审核过程也授予学生账号：过程内部先校验审核人绑定与班级范围，学生越权读取
-- 会被拒绝并写入 access_denied_log（测试 test_10 覆盖该路径）；写类过程仍只给审核角色。
GRANT EXECUTE ON PROCEDURE student_assessment.read_review_item TO 'sa_reviewer', 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.read_evidence TO 'sa_reviewer', 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.review_item_diff TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.publish_year TO 'sa_publisher';
GRANT SELECT ON student_assessment.public_notice TO 'sa_student', 'sa_analyst';
GRANT EXECUTE ON PROCEDURE student_assessment.my_evidence TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_submission_history TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.web_projects TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.set_base_assessment TO 'sa_reviewer', 'sa_admin';
GRANT EXECUTE ON PROCEDURE student_assessment.web_base_scores TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.web_ai_context TO 'sa_reviewer';
-- web_ai_draft 经 lock_review_item 限定为绑定审核员范围，管理员无审核员绑定、调用必被拒，
-- 故不授 EXECUTE（与 web_save_ai_draft 同口径）；管理员经 ai_review 的 SELECT 只读监控。
GRANT EXECUTE ON PROCEDURE student_assessment.web_ai_draft TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.web_save_ai_draft TO 'sa_reviewer';

-- 管理员：主数据可写（触发器继续守住规则版本、学年状态机、登录名互斥等不变量），
-- 业务数据只读监控；证明材料仅授权元数据列（不含 file_body），隐私访问日志可查。
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.class_group TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.student TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.reviewer TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.assessment_rule TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.assessment_project TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.academic_year TO 'sa_admin';
GRANT SELECT ON student_assessment.student_year_assessment TO 'sa_admin';
GRANT SELECT ON student_assessment.application_form TO 'sa_admin';
GRANT SELECT ON student_assessment.application_item TO 'sa_admin';
GRANT SELECT (evidence_id, item_id, file_name, storage_location, sha256, uploaded_at, active)
    ON student_assessment.evidence TO 'sa_admin';
GRANT SELECT ON student_assessment.review_record TO 'sa_admin';
GRANT SELECT ON student_assessment.review_snapshot_item TO 'sa_admin';
GRANT SELECT ON student_assessment.review_snapshot_evidence TO 'sa_admin';
GRANT SELECT ON student_assessment.submission_log TO 'sa_admin';
GRANT SELECT ON student_assessment.submission_snapshot_item TO 'sa_admin';
GRANT SELECT ON student_assessment.assessment_result TO 'sa_admin';
GRANT SELECT ON student_assessment.component_score TO 'sa_admin';
GRANT SELECT ON student_assessment.assessment_ranking TO 'sa_admin';
GRANT SELECT ON student_assessment.ai_review TO 'sa_reviewer', 'sa_admin';
GRANT SELECT ON student_assessment.privacy_access_log TO 'sa_admin';
GRANT EXECUTE ON PROCEDURE student_assessment.abandon_form TO 'sa_admin';
GRANT EXECUTE ON PROCEDURE student_assessment.publish_year TO 'sa_admin';
GRANT SELECT ON student_assessment.access_denied_log TO 'sa_admin';
GRANT SELECT ON student_assessment.admin_operation_log TO 'sa_admin';
GRANT SELECT ON student_assessment.admin_stalled_forms TO 'sa_admin';

-- v7：公示校验码、材料查重、规则版本链、状态变更日志
GRANT EXECUTE ON PROCEDURE student_assessment.verify_publication
    TO 'sa_student', 'sa_reviewer', 'sa_analyst', 'sa_publisher', 'sa_admin';
GRANT SELECT ON student_assessment.publication_batch TO 'sa_admin';
GRANT EXECUTE ON PROCEDURE student_assessment.check_evidence_duplicates TO 'sa_reviewer';
GRANT SELECT ON student_assessment.evidence_duplicates TO 'sa_admin';
GRANT SELECT ON student_assessment.rule_version_chain TO 'sa_admin', 'sa_analyst';
GRANT SELECT ON student_assessment.status_change_log TO 'sa_admin';


-- 已启用学年引用的评分口径保留原版本。变更评分请建立新版本。
DELIMITER $$
CREATE TRIGGER keep_year_rule BEFORE UPDATE ON academic_year FOR EACH ROW
BEGIN
    IF OLD.status <> 'draft' AND (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on
                                  OR NEW.opens_at <> OLD.opens_at) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年启用后不可修改起止日期与开放时刻';
    END IF;
    -- 截止时间只许后延；open→review 的同一句 UPDATE 允许把截止时间提前到当前时刻
    -- （即"手工提前关闭申报"，02 演示数据所用的快进模式）
    IF NEW.status = OLD.status AND OLD.status IN ('open','review','published')
       AND NEW.deadline_at < OLD.deadline_at THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '截止时间只能向后延';
    END IF;
    IF OLD.status = 'published' AND NEW.status <> 'published' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已公示学年不能退回';
    END IF;
    IF OLD.status <> 'draft' AND NEW.status = 'draft' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已启用学年不能退回草稿';
    END IF;
    -- 前跳守卫：转入 published 必须已存在本学年批次校验码（即必经 publish_year 生成结果/排名/校验码），
    -- 阻断直接 UPDATE 置 published 绕过计分与校验码（publish_year 同事务先插 publication_batch 再 UPDATE）。
    IF NEW.status = 'published' AND OLD.status <> 'published'
       AND NOT EXISTS (SELECT 1 FROM publication_batch WHERE year_id = NEW.year_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年公示须经发布流程生成结果与校验码';
    END IF;
END$$

-- 学年日期区间互不重叠（MySQL 无跨行约束，用触发器保证）。
-- 更新仅在日期区间实际变化时检查，并按主键排除自身。
CREATE TRIGGER check_year_overlap_ins BEFORE INSERT ON academic_year FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM academic_year
        WHERE NEW.starts_on <= ends_on AND starts_on <= NEW.ends_on
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年日期区间不能与已有学年重叠';
    END IF;
END$$

CREATE TRIGGER check_year_overlap_upd BEFORE UPDATE ON academic_year FOR EACH ROW
BEGIN
    IF (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on) AND EXISTS (
        SELECT 1 FROM academic_year
        WHERE year_id <> NEW.year_id
          AND NEW.starts_on <= ends_on AND starts_on <= NEW.ends_on
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年日期区间不能与已有学年重叠';
    END IF;
END$$

-- 学生与审核人的登录名互斥：同一数据库账号不能同时绑定两种身份，
-- 防止一人既申报又审核（甚至审核自己）。MySQL 无跨表 UNIQUE/断言，故用触发器。
CREATE TRIGGER student_login_not_reviewer_ins BEFORE INSERT ON student FOR EACH ROW
BEGIN
    IF EXISTS (SELECT 1 FROM reviewer WHERE login_name = NEW.login_name) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定审核人员';
    END IF;
END$$

CREATE TRIGGER student_login_not_reviewer_upd BEFORE UPDATE ON student FOR EACH ROW
BEGIN
    IF NEW.login_name <> OLD.login_name AND EXISTS (
        SELECT 1 FROM reviewer WHERE login_name = NEW.login_name
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定审核人员';
    END IF;
END$$

CREATE TRIGGER reviewer_login_not_student_ins BEFORE INSERT ON reviewer FOR EACH ROW
BEGIN
    IF EXISTS (SELECT 1 FROM student WHERE login_name = NEW.login_name) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定学生';
    END IF;
END$$

CREATE TRIGGER reviewer_login_not_student_upd BEFORE UPDATE ON reviewer FOR EACH ROW
BEGIN
    IF NEW.login_name <> OLD.login_name AND EXISTS (
        SELECT 1 FROM student WHERE login_name = NEW.login_name
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定学生';
    END IF;
END$$

-- 3NF 化后，原复合外键 (form_id, rule_id) 与 (rule_id, project_id) 提供的
-- "条目项目必须属于表单学年的规则版本"这一跨表约束改由此处触发器保证。
CREATE TRIGGER check_item_project_rule_ins BEFORE INSERT ON application_item FOR EACH ROW
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM application_form f
        JOIN student_year_assessment a ON a.student_id = f.student_id AND a.year_id = f.year_id
        JOIN assessment_project p ON p.project_id = NEW.project_id
        WHERE f.form_id = NEW.form_id AND p.rule_id = a.rule_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '项目不属于该学生本年度的规则';
    END IF;
    IF NEW.claimed_score > (SELECT score_cap FROM assessment_project
                            WHERE project_id = NEW.project_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报分不能超过单项封顶分';
    END IF;
    IF NEW.status <> 'withdrawn' AND EXISTS (
        SELECT 1 FROM assessment_project p
        WHERE p.project_id = NEW.project_id AND p.max_items IS NOT NULL
          AND (SELECT COUNT(*) FROM application_item i
               WHERE i.form_id = NEW.form_id AND i.project_id = NEW.project_id
                 AND i.status <> 'withdrawn') >= p.max_items
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该项目本年度申报条数已达上限';
    END IF;
END$$

CREATE TRIGGER check_item_project_rule_upd BEFORE UPDATE ON application_item FOR EACH ROW
BEGIN
    IF (NEW.form_id <> OLD.form_id OR NEW.project_id <> OLD.project_id) AND NOT EXISTS (
        SELECT 1 FROM application_form f
        JOIN student_year_assessment a ON a.student_id = f.student_id AND a.year_id = f.year_id
        JOIN assessment_project p ON p.project_id = NEW.project_id
        WHERE f.form_id = NEW.form_id AND p.rule_id = a.rule_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '项目不属于该学生本年度的规则';
    END IF;
    IF NEW.claimed_score > (SELECT score_cap FROM assessment_project
                            WHERE project_id = NEW.project_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报分不能超过单项封顶分';
    END IF;
    IF NEW.status <> 'withdrawn' AND EXISTS (
        SELECT 1 FROM assessment_project p
        WHERE p.project_id = NEW.project_id AND p.max_items IS NOT NULL
          AND (SELECT COUNT(*) FROM application_item i
               WHERE i.form_id = NEW.form_id AND i.project_id = NEW.project_id
                 AND i.item_id <> NEW.item_id AND i.status <> 'withdrawn') >= p.max_items
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该项目本年度申报条数已达上限';
    END IF;
END$$

CREATE PROCEDURE require_unused_rule(IN p_rule INT UNSIGNED)
READS SQL DATA
BEGIN
    IF EXISTS (SELECT 1 FROM student_year_assessment WHERE rule_id = p_rule) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已启用/已使用的规则版本及其项目不可修改';
    END IF;
END$$

CREATE TRIGGER keep_rule_version BEFORE UPDATE ON assessment_rule FOR EACH ROW
BEGIN
    CALL require_unused_rule(OLD.rule_id);
END$$

CREATE TRIGGER keep_project_insert BEFORE INSERT ON assessment_project FOR EACH ROW
BEGIN
    CALL require_unused_rule(NEW.rule_id);
END$$

CREATE TRIGGER keep_project_update BEFORE UPDATE ON assessment_project FOR EACH ROW
BEGIN
    CALL require_unused_rule(OLD.rule_id);
    IF OLD.rule_id <> NEW.rule_id THEN
        CALL require_unused_rule(NEW.rule_id);
    END IF;
END$$

CREATE TRIGGER keep_project_delete BEFORE DELETE ON assessment_project FOR EACH ROW
BEGIN
    CALL require_unused_rule(OLD.rule_id);
END$$

-- A/B1 分项满分随规则 a_cap/b1_cap 变化，CHECK 无法跨表取规则，故由本触发器按规则校验。
-- 经 result_id→assessment_result→student_year_assessment→assessment_rule 取该生该年所用规则的满分。
CREATE TRIGGER check_component_cap_ins BEFORE INSERT ON component_score FOR EACH ROW
BEGIN
    DECLARE v_a_cap, v_b1_cap DECIMAL(5,2);
    IF NEW.component IN ('A','B1') THEN
        SELECT ar.a_cap, ar.b1_cap INTO v_a_cap, v_b1_cap
        FROM assessment_result r
        JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
        JOIN assessment_rule ar ON ar.rule_id = a.rule_id
        WHERE r.result_id = NEW.result_id;
        IF NEW.component = 'A' AND NEW.score > v_a_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '基本素质A超过规则满分';
        END IF;
        IF NEW.component = 'B1' AND NEW.score > v_b1_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学业成绩B1超过规则满分';
        END IF;
    END IF;
END$$

-- v13 C3：补 BEFORE UPDATE 同口径封顶校验。公示冻结分项若被直接 UPDATE 改分，
-- 原 INSERT-only 触发器不会拦截，可绕过规则满分约束；UPDATE 同样按 NEW.result_id
-- 对应学生该学年的规则取 a_cap/b1_cap 校验（若同时改了 result_id，按改后归属校验）。
CREATE TRIGGER check_component_cap_upd BEFORE UPDATE ON component_score FOR EACH ROW
BEGIN
    DECLARE v_a_cap, v_b1_cap DECIMAL(5,2);
    IF NEW.component IN ('A','B1') THEN
        SELECT ar.a_cap, ar.b1_cap INTO v_a_cap, v_b1_cap
        FROM assessment_result r
        JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
        JOIN assessment_rule ar ON ar.rule_id = a.rule_id
        WHERE r.result_id = NEW.result_id;
        IF NEW.component = 'A' AND NEW.score > v_a_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '基本素质A超过规则满分';
        END IF;
        IF NEW.component = 'B1' AND NEW.score > v_b1_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学业成绩B1超过规则满分';
        END IF;
    END IF;
END$$
DELIMITER ;

-- 主数据与学年状态变更审计（AFTER 单语句触发器，无需切换 DELIMITER）。
-- operator_login 取执行 SQL 的数据库账号；EVENT 自动推进的学年状态变更
-- 归属于事件定义者账号（安装账号），见使用说明。审计表刻意不设外键：
-- 审计写入永远不应因业务数据问题而失败。
CREATE TRIGGER audit_class_group_ins AFTER INSERT ON class_group FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'class_group:insert', NEW.class_id, NEW.class_name);

CREATE TRIGGER audit_class_group_upd AFTER UPDATE ON class_group FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'class_group:update', NEW.class_id,
        CONCAT(OLD.class_name, ' -> ', NEW.class_name));

CREATE TRIGGER audit_class_group_del AFTER DELETE ON class_group FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'class_group:delete', OLD.class_id, OLD.class_name);

CREATE TRIGGER audit_student_ins AFTER INSERT ON student FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'student:insert', NEW.student_id,
        CONCAT('name=', NEW.student_name, ', class=', NEW.class_id, ', login=', NEW.login_name));

CREATE TRIGGER audit_student_upd AFTER UPDATE ON student FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'student:update', NEW.student_id,
        CONCAT('name:', OLD.student_name, '->', NEW.student_name,
               ', class:', OLD.class_id, '->', NEW.class_id,
               ', login:', OLD.login_name, '->', NEW.login_name));

CREATE TRIGGER audit_student_del AFTER DELETE ON student FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'student:delete', OLD.student_id,
        CONCAT('name=', OLD.student_name, ', login=', OLD.login_name));

CREATE TRIGGER audit_reviewer_ins AFTER INSERT ON reviewer FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'reviewer:insert', NEW.reviewer_id,
        CONCAT('name=', NEW.reviewer_name, ', role=', NEW.review_role,
               ', class=', COALESCE(NEW.class_id, 'NULL'), ', login=', NEW.login_name));

CREATE TRIGGER audit_reviewer_upd AFTER UPDATE ON reviewer FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'reviewer:update', NEW.reviewer_id,
        CONCAT('name:', OLD.reviewer_name, '->', NEW.reviewer_name,
               ', role:', OLD.review_role, '->', NEW.review_role,
               ', class:', COALESCE(OLD.class_id, 'NULL'), '->', COALESCE(NEW.class_id, 'NULL'),
               ', login:', OLD.login_name, '->', NEW.login_name));

CREATE TRIGGER audit_reviewer_del AFTER DELETE ON reviewer FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'reviewer:delete', OLD.reviewer_id,
        CONCAT('name=', OLD.reviewer_name, ', login=', OLD.login_name));

CREATE TRIGGER audit_rule_ins AFTER INSERT ON assessment_rule FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_rule:insert', NEW.rule_id,
        CONCAT(NEW.rule_name, ' ', NEW.version_no));

CREATE TRIGGER audit_rule_upd AFTER UPDATE ON assessment_rule FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_rule:update', NEW.rule_id,
        CONCAT(OLD.rule_name, ' ', OLD.version_no, ' -> ', NEW.rule_name, ' ', NEW.version_no));

CREATE TRIGGER audit_rule_del AFTER DELETE ON assessment_rule FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_rule:delete', OLD.rule_id,
        CONCAT(OLD.rule_name, ' ', OLD.version_no));

CREATE TRIGGER audit_project_ins AFTER INSERT ON assessment_project FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_project:insert', NEW.project_id,
        CONCAT('rule=', NEW.rule_id, ', component=',
               CASE WHEN NEW.rule_key IN ('social_work','volunteer','practice') THEN 'C' ELSE 'B2' END,
               ', key=', NEW.rule_key,
               ', name=', NEW.project_name, ', cap=', NEW.score_cap));

CREATE TRIGGER audit_project_upd AFTER UPDATE ON assessment_project FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_project:update', NEW.project_id,
        CONCAT('rule:', OLD.rule_id, '->', NEW.rule_id,
               ', name:', OLD.project_name, '->', NEW.project_name,
               ', cap:', OLD.score_cap, '->', NEW.score_cap));

CREATE TRIGGER audit_project_del AFTER DELETE ON assessment_project FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_project:delete', OLD.project_id,
        CONCAT('rule=', OLD.rule_id, ', name=', OLD.project_name));

CREATE TRIGGER audit_year_ins AFTER INSERT ON academic_year FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'academic_year:insert', NEW.year_id,
        CONCAT('status=', NEW.status, ', window=', NEW.starts_on, '..', NEW.ends_on));

CREATE TRIGGER audit_year_upd AFTER UPDATE ON academic_year FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'academic_year:update', NEW.year_id,
        CONCAT('status:', OLD.status, '->', NEW.status,
               ', deadline:', OLD.deadline_at, '->', NEW.deadline_at));

CREATE TRIGGER audit_year_del AFTER DELETE ON academic_year FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'academic_year:delete', OLD.year_id,
        CONCAT('status=', OLD.status));

-- 状态机变更日志触发器：仅在 status 实际迁移时写入（单语句 INSERT ... SELECT ... WHERE，
-- 无需 BEGIN 块）。changed_by 取当前连接账号；事件调度器推进时记为事件定义者账号。
CREATE TRIGGER log_year_status AFTER UPDATE ON academic_year FOR EACH ROW
INSERT INTO status_change_log(entity_type, entity_id, old_status, new_status, changed_by)
SELECT 'academic_year', NEW.year_id, OLD.status, NEW.status, SUBSTRING_INDEX(USER(), '@', 1)
FROM DUAL WHERE OLD.status <> NEW.status;

CREATE TRIGGER log_form_status AFTER UPDATE ON application_form FOR EACH ROW
INSERT INTO status_change_log(entity_type, entity_id, old_status, new_status, changed_by)
SELECT 'application_form', NEW.form_id, OLD.status, NEW.status, SUBSTRING_INDEX(USER(), '@', 1)
FROM DUAL WHERE OLD.status <> NEW.status;

CREATE TRIGGER log_item_status AFTER UPDATE ON application_item FOR EACH ROW
INSERT INTO status_change_log(entity_type, entity_id, old_status, new_status, changed_by)
SELECT 'application_item', NEW.item_id, OLD.status, NEW.status, SUBSTRING_INDEX(USER(), '@', 1)
FROM DUAL WHERE OLD.status <> NEW.status;

-- 学年状态自动推进（事件调度器）：到开放时刻自动开启，过截止时刻自动转入审核，
-- 状态机由数据库自己推进，应用层与人工只需负责建学年与公示两个端点。
-- 事件调度器默认关闭，此处持久化开启（写入 mysqld-auto.cnf，重启后仍然生效），
-- 需 SYSTEM_VARIABLES_ADMIN 权限（安装账号具备）；demo.py 另以 --event-scheduler=ON 启动兜底。
-- 若事件被关闭，学年不会自动切换，可用 03_网页接口.sql 的 web_close_submissions 手工兜底。
SET PERSIST event_scheduler = ON;

CREATE EVENT open_due_years
ON SCHEDULE EVERY 1 MINUTE
DO UPDATE academic_year SET status = 'open'
   WHERE status = 'draft' AND UTC_TIMESTAMP() >= opens_at;

CREATE EVENT review_due_years
ON SCHEDULE EVERY 1 MINUTE
DO UPDATE academic_year SET status = 'review'
   WHERE status = 'open' AND UTC_TIMESTAMP() >= deadline_at;
