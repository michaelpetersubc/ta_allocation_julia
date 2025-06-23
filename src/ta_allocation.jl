"""
    Deferred Acceptance algorithm for VSE TA allocations
    James Yuming Yu, Vancouver School of Economics, 18 May 2022
"""

"""
"username"
    help = "the API username"
    arg_type = String
    required = true
"pass"
    help = "the API password"
    arg_type = String
    required = true
"server"
    help = "the API server URL (without endpoint)"
    arg_type = String
    required = true

"--host"
    help = "db hostname"
    arg_type = String
    default = ""
"--user"
    help = "db username"
    arg_type = String
    default = ""
"--password"
    help = "db password"
    arg_type = String
    default = ""
"--database"
    help = "db location name"
    arg_type = String
    default = ""
"--port"
    help = "db port"
    arg_type = Int
    default = 0
"""

module ta_allocation
    using ArgParse, DataStructures, HTTP, JSON, MySQL, Random


    function get_switches()
        """
            *** helper function for reading command-line arguments ***
            - given a template for command-line arguments, read given text off the command line
        """
        config = ArgParseSettings()
        @add_arg_table config begin
            "--verbose"
                help = "whether to print matching result at the end"
                arg_type = Bool
                default = false
        end
        return parse_args(config)
    end


    function get_path(user, pass, serv)
        """
            *** helper function for generating URLs ***
            - given authentication data, generate login URL
        """
        return string("http://", user, ":", pass, "@", serv, "/")
    end


    function download(route, endpoint)
        """
            *** helper function for downloading data ***
            - given an address, download a webpage's data as JSON text
        """
        return JSON.Parser.parse(String(HTTP.get(string(route, endpoint)).body))
    end


    function should_accept(is_student, do_first_allocation, agent, matched_students, unmatched_courses)
        """
            *** helper function to implement dual-round matching criterion ***
            - given input flags, determine if an agent should be included in the matching
        """
        # handle the inclusion state based on input flags
        # if first allocation:
        # - phd students only
        # - if is_student then ta_type must be 1
        # - otherwise does not matter
        # else:
        # - must take in every student that has not been previously matched
        # -- if student is not in matched_students, add
        # - must take in every course that has not been previously matched
        # -- if course is in unmatched_courses, add
        if do_first_allocation == true # round 1
            if is_student == true # student, only PhD
                return agent["ta_type"] == "1"
            else # course, and all courses are included
                return true
            end
        else # round 2
            if is_student == true # student, must not have been previously matched
                return !(agent["id"] in matched_students)
            else # course, must not have been previously matched
                return agent["id"] in unmatched_courses
            end
        end
    end     
        

    function agent_list_to_agent_dict(list_of_agents, is_student, do_first_allocation, matched_students, unmatched_courses)
        """
            *** helper function for converting a list of agents into an indexed dictionary ***
            - given a list of agents, map them to a dict indexed by agent ID
        """
        agent_pref = Dict{String, Dict{String, Any}}()
        for agent in list_of_agents
            if should_accept(is_student, do_first_allocation, agent, matched_students, unmatched_courses)
                # for every agent, add empty containers for preferences and matching 
                if agent["id"] in keys(agent_pref) # catch duplicates
                    if is_student
                        println("WARNING: ", agent["id"], " exists twice in students")
                    else
                        println("WARNING: ", agent["id"], " exists twice in courses")
                    end
                end
                agent_pref[agent["id"]] = Dict("info" => agent, "preferences" => Dict{String, Any}(), "rand_score" => parse(Float64, agent["rand_score"]), "match" => "")
            end
        end
        return agent_pref
    end


    function push_preferences(dict_of_agents, agent_pref, primary_label, secondary_label, dict_of_other_agents)
        """
            *** helper function for adding a list of agent preferences to a dict of agents ***
            - given a list of agent preferences, map them to a dict using IDs of the agents being ranked
        """
        initial_pref = DefaultDict{String, Dict{String, Any}}(() -> Dict{String, Any}())
        for p in agent_pref
            # ensure agents actually exist
            if p[primary_label] in keys(dict_of_agents) && p[secondary_label] in keys(dict_of_other_agents)
                # add preference to dict using agent IDs for indexing
                dict_of_agents[p[primary_label]]["preferences"][p[secondary_label]] = parse(Float64, p["score"])

                # also log it to a separate preference dictionary for reference later
                initial_pref[p[primary_label]][p[secondary_label]] = parse(Float64, p["score"])
            end
        end
        return dict_of_agents, initial_pref
    end


    function collect_missing_preferences(dict_of_agents, dict_of_other_agents, initial_pref)
        """
            *** helper function for adding unmarked preferences to a preference dict ***
            - given a dict of agents to be ranked, mark previously unranked agents as 
            mutually equivalent and less-preferred to previously ranked agents
        """
        for primary_agent in dict_of_agents, secondary_agent in dict_of_other_agents
            if !(secondary_agent.first in keys(primary_agent.second["preferences"]))
                # give a zero score to unranked agents that need to be matched
                dict_of_agents[primary_agent.first]["preferences"][secondary_agent.first] = 0.0
                initial_pref[primary_agent.first][secondary_agent.first] = 0.0
            end
        end
        return dict_of_agents, initial_pref
    end


    function compile_preferences(dict_of_agents, list_of_preferences, primary_agent, dict_of_other_agents)
        """
            *** helper function for converting a list of preferences into an indexed dictionary ***
            - given a dict of agents and a list of individual cardinal preferences, 
            map them to a two-level dict indexed by primary agent and sub-indexed by the agent being ranked
        """
        if primary_agent == "student"
            primary_label = "student_allocation_id"
            secondary_label = "course_allocation_id"
        else
            primary_label = "course_allocation_id"
            secondary_label = "student_allocation_id"
        end

        # 1. push the list of preferences into the dictionary based on agent IDs
        dict_of_agents, initial_pref = push_preferences(dict_of_agents, list_of_preferences, primary_label, secondary_label, dict_of_other_agents)

        # 2. populate any missing preferences as mutually-equivalent and less-preferred to given preferences
        dict_of_agents, initial_pref = collect_missing_preferences(dict_of_agents, dict_of_other_agents, initial_pref)
        
        # 3. return results
        return dict_of_agents, initial_pref
    end


    function validate_degree(dict_of_agents, initial_pref, primary_agent, dict_of_other_agents)
        """
            *** helper function for ensuring TA credentials are valid ***
            - given agent preferences, invalidate those which would put 
            an MA TA in a PhD-only position
        """
        if primary_agent == "student"
            # primary agent is a student, so first check is type of courses
            first_type = "1" # PhD position
            second_type = "2" # MA student
        else
            # primary agent is a course, so first check is type of students
            first_type = "2" # MA student
            second_type = "1" # PhD position
        end
        for agent in dict_of_agents
            own_type = agent.second["info"]["ta_type"]
            # iterate over preferences
            for pref in keys(agent.second["preferences"])
                # compare TA type of preference to own TA type
                if dict_of_other_agents[pref]["info"]["ta_type"] == first_type && own_type == second_type
                    # MA student and PhD course, invalid
                    dict_of_agents[agent.first]["preferences"][pref] = -1.0
                    initial_pref[agent.first][pref] = -1.0
                end
            end
        end
        return dict_of_agents, initial_pref
    end


    function retrieve_best_preference(starting_id, starting_rank, preferences, dict_of_agents)
        """
            *** helper function to break ties in preferences ***
            - given a preference list, highest cardinal rank and tiebreak rule, return highest-ranked preference
        """
        best_tiebreak_score = dict_of_agents[starting_id]["rand_score"]  
        best_id = starting_id
        # break any ties that have the same cardinal score (starting_rank)
        for preference in preferences
            # if the cardinal score of this preference is the same as the given one...
            if starting_rank == preference.second 
                # obtain the tiebreak score of this preference; all preferences have a unique score
                new_tiebreak_score = dict_of_agents[preference.first]["rand_score"]
                if new_tiebreak_score > best_tiebreak_score # if the score is better...
                    # update the score and save the new best course id
                    best_tiebreak_score = new_tiebreak_score
                    best_id = preference.first
                end
            end
            # otherwise, if we didn't find any better scores, the given one is the tiebreak result
        end
        return best_id
    end


    function is_better(preferences, applicant_id, existing_id, dict_of_agents)
        """
            *** helper function to compare two ranked agents ***
            - given a preference list and tiebreak rule, return the higher-ranked of two agents
        """
        rank_of_applicant = preferences[applicant_id]
        rank_of_current = preferences[existing_id]
        return rank_of_applicant > rank_of_current || # either the cardinal score is better...
            (rank_of_applicant == rank_of_current && # or they are the same but the tiebreak rank is better
            (dict_of_agents[applicant_id]["rand_score"] > dict_of_agents[existing_id]["rand_score"]))
    end


    function deferred_acceptance(dict_of_students, dict_of_courses, verb = false)
        """
            *** function to apply the deferred acceptance algorithm to TA assignment ***
            - given preferences and tiebreaking rules, return a stable matching of TAs to courses
        """
        while true
            did_an_action = false
            # - iterate over all students --------------------------------------------------------------------
            for student_id in keys(dict_of_students)
                if verb println("checking ", student_id) end
                preferences = dict_of_students[student_id]["preferences"]    
                ## - check if needs to be matched ------------------------------------------------------------
                if dict_of_students[student_id]["match"] == "" && length(preferences) > 0
                    if verb println(" needs to be matched using pref list") end
                    next_preference = findmax(preferences)
                    ### - check if preferences are nonnegative -----------------------------------------------
                    if next_preference[1] < 0 # if cardinal rank is negative, all usable preferences exhausted
                        if verb println("  remaining preference (", next_preference[2], ") is negative, student is done") end
                        course_id = next_preference[2]
                        dict_of_students[student_id]["match"] = "UNMATCHED"
                    else
                        course_id = retrieve_best_preference(next_preference[2], next_preference[1], preferences, dict_of_courses)
                        if verb println("  locating best preference ", course_id) end
                        course = dict_of_courses[course_id]
                        #### - check if student can be matched with preference -------------------------------
                        if course["preferences"][student_id] >= 0 # if the student is acceptable to the course
                            if course["match"] == "" # if course has space
                                if verb println("   course has space") end
                                course["match"] = student_id # add student
                                dict_of_students[student_id]["match"] = course_id
                            elseif is_better(course["preferences"], student_id, course["match"], dict_of_students)
                                if verb println("   student is better than ", course["match"]) end
                                dict_of_students[course["match"]]["match"] = "" # reject existing student
                                course["match"] = student_id # add new student
                                dict_of_students[student_id]["match"] = course_id
                            elseif verb
                                println("   student is worse")
                            end # otherwise, don't change anything
                        end
                        #### ---------------------------------------------------------------------------------
                    end
                    ### --------------------------------------------------------------------------------------
                    delete!(dict_of_students[student_id]["preferences"], course_id)
                    did_an_action = true
                    if verb println(" removing preference from pref list") end
                end
                ## -------------------------------------------------------------------------------------------
            end
            # ------------------------------------------------------------------------------------------------
            if !did_an_action break end # if no further matches are possible, we are done
        end
        return dict_of_students, dict_of_courses
    end
        

    function validate_matching_stability(dict_of_students, dict_of_courses, initial_student_pref, initial_course_pref, verb = false)
        """
            *** function to validate whether a matching is stable ***
            - given a matching, return true if no unmatched pair would prefer to be matched
            and no matched agent would prefer to remain unmatched
        """
        for student in dict_of_students, course in dict_of_courses
            # a pair would prefer to be matched if both of the following are true:
            #     the student prefers the course to its own match
            #     the course prefers the student to its own match
            if initial_student_pref[student.first][course.first] >= 0 && initial_course_pref[course.first][student.first] >= 0 # if could match...
                # matching is preferred in two cases: the match is better than existing match, or the agent is currently unmatched
                if (student.second["match"] in ["", "UNMATCHED"] || 
                        is_better(initial_student_pref[student.first], course.first, student.second["match"], dict_of_courses)) &&
                    (course.second["match"] in ["", "UNMATCHED"] || 
                        is_better(initial_course_pref[course.first], student.first, course.second["match"], dict_of_students))
                    println("ERROR: student ", student.first, " and course ", course.first, " would prefer to pair; match unstable")
                    return false # matching this pair would be better so this is not stable
                elseif verb
                    if student.second["match"] in ["", "UNMATCHED"]
                        print("student ", student.first, " unmatched; ")
                    else
                        print("student ", student.first, " prefers existing match ", student.second["match"], " as ", initial_student_pref[student.first][student.second["match"]], " betterness ", is_better(initial_student_pref[student.first], course.first, student.second["match"], dict_of_courses), "; ")
                    end
                    println("prefers new match ", course.first, " as ", initial_student_pref[student.first][course.first])
                    if course.second["match"] in ["", "UNMATCHED"]
                        print("course ", course.first, " unmatched; ")
                    else
                        print("course ", course.first, " prefers existing match ", course.second["match"], " as ", initial_course_pref[course.first][course.second["match"]], " betterness ", is_better(initial_course_pref[course.first], student.first, course.second["match"], dict_of_students), "; ")
                    end
                    println("prefers new match ", student.first, " as ", initial_course_pref[course.first][student.first])
                    if student.second["match"] in ["", "UNMATCHED"]
                        print("no ")
                    else
                        print(is_better(initial_student_pref[student.first], course.first, student.second["match"], dict_of_courses), " ")
                    end
                    if course.second["match"] in ["", "UNMATCHED"]
                        print("no")
                    else
                        print(is_better(initial_course_pref[course.first], student.first, course.second["match"], dict_of_students))
                    end
                    println()
                end
            elseif verb
                println("negative pref: ", student.first, " ", initial_student_pref[student.first][course.first], " & ", course.first, " ", initial_course_pref[course.first][student.first])
            end
        end
        # ensure no agent has a negative-ranked match
        for student in dict_of_students
            if !(student.second["match"] in ["", "UNMATCHED"]) && initial_student_pref[student.first][student.second["match"]] < 0
                println("ERROR: student ", student.first, " has negative match ", student.second["match"], "; match unstable")
                return false
            elseif verb
                if student.second["match"] in ["", "UNMATCHED"]
                    println("ok: student ", student.first, " is unmatched")
                else
                    println("ok: student ", student.first, " has match ", student.second["match"], " with rank ", initial_student_pref[student.first][student.second["match"]])
                end
            end
        end
        for course in dict_of_courses
            if !(course.second["match"] in ["", "UNMATCHED"]) && initial_course_pref[course.first][course.second["match"]] < 0
                println("ERROR: course ", course.first, " has negative match ", course.second["match"], "; match unstable")
                return false
            elseif verb
                if course.second["match"] in ["", "UNMATCHED"]
                    println("ok: course ", course.first, " is unmatched")
                else
                    println("ok: course ", course.first, " has match ", course.second["match"], " with rank ", initial_course_pref[course.first][course.second["match"]])
                end
            end
        end
        return true
    end


    function print_student_matching(dict_of_students, dict_of_courses, initial_student_pref)
        """
            *** helper function to print student matching ***
            - given student and course matching, print student matching data
        """
        println("STUDENT MATCHING:")
        for student in sort([a for a in dict_of_students], by = x->x.first)
            print(student.first, " ", ["PhD", "MA"][parse(Int, student.second["info"]["ta_type"])], " ")
            if !(student.second["match"] in ["", "UNMATCHED"])
                course = dict_of_courses[student.second["match"]]
                println("ECON ", course["info"]["course"], " ", course["info"]["short_title"], " ", student.second["match"])
            else
                println("no hire")
            end
            print("preferences: ")
            for pref in sort([p for p in initial_student_pref[student.first]], by = x -> x.second, rev = true)
                if pref.second > 0
                    print(dict_of_courses[pref.first]["info"]["course"], "(", pref.first, ") ")
                end
            end
            println()
            println()
        end
        println()
    end


    function print_course_matching(dict_of_courses, initial_course_pref)
        """
            *** helper function to print course matching ***
            - given course matching, print course matching data
        """
        println("COURSE MATCHING:")
        for course in sort([h for h in dict_of_courses], by = x->string(x.second["info"]["course"], x.first))
            print(course.first, " ECON ", course.second["info"]["course"], " (", course.second["info"]["short_title"],  ", ", ["PhD", "MA"][parse(Int, course.second["info"]["ta_type"])], ") ")
            if !(course.second["match"] in ["", "UNMATCHED"])
                println(course.second["match"])
            else
                println("no hire")
            end
            print("preferences: ")
            for pref in sort([p for p in initial_course_pref[course.first]], by = x -> x.second, rev = true)
                if pref.second > 0
                    print(pref.first, " ")
                end
            end
            println()
            println()
        end
        println()
    end


    function main(user, pass, serv, verb, do_first_allocation, matched_students, unmatched_courses)
        """
            *** function to run the TA allocation algorithm ***
            - parse command-line and API endpoints to return matching pairs
        """
        # 1. read command-line settings (outside of main())
        
        # 2. download student list, course list and preferences
        route = get_path(user, pass, serv)
        list_of_students = download(route, "student_allocations")
        list_of_courses = download(route, "course_allocations")
        student_preferences = download(route, "student_preferences")
        course_preferences = download(route, "course_preferences")
        
        # 3. compile initial preferences
        dict_of_students = agent_list_to_agent_dict(list_of_students, true, do_first_allocation, matched_students, unmatched_courses)
        dict_of_courses = agent_list_to_agent_dict(list_of_courses, false, do_first_allocation, matched_students, unmatched_courses)
        if verb
            println("There are ", length(keys(list_of_students)), " students")
            println("There are ", length(keys(list_of_courses)), " courses")
        end
        seen_scores_student = []
        seen_scores_course = []
        for student in dict_of_students
            if student.second["rand_score"] in seen_scores_student
                println("ERROR: score ", student.second["rand_score"], " for student ", student.first, " is not a unique tiebreak score")
            end
            push!(seen_scores_student, student.second["rand_score"])
        end
        for course in dict_of_courses
            if course.second["rand_score"] in seen_scores_course
                println("ERROR: score ", course.second["rand_score"], " for course ", course.first, " is not a unique tiebreak score")
            end
            push!(seen_scores_course, course.second["rand_score"])
        end
        dict_of_students, initial_student_pref = compile_preferences(dict_of_students, student_preferences, "student", dict_of_courses)
        dict_of_courses, initial_course_pref = compile_preferences(dict_of_courses, course_preferences, "course", dict_of_students)
        
        # 4. ensure no invalid pairings (MA TAs in PhD positions) could be generated
        dict_of_students, initial_student_pref = validate_degree(dict_of_students, initial_student_pref, "student", dict_of_courses)
        dict_of_courses, initial_course_pref = validate_degree(dict_of_courses, initial_course_pref, "course", dict_of_students)
        
        # 5. run the algorithm while unmatched students still have unchecked preferences
        dict_of_students, dict_of_courses = deferred_acceptance(dict_of_students, dict_of_courses, verb)
        
        # 6. validate stability of matching
        if validate_matching_stability(dict_of_students, dict_of_courses, initial_student_pref, initial_course_pref, verb)
            if verb 
                println("matching is stable")
                println()
            end
        else
            if verb
                println("matching is NOT STABLE")
                println()
            end
        end
        
        # 7. print results if verbose is on
        if verb
            print_student_matching(dict_of_students, dict_of_courses, initial_student_pref)
            print_course_matching(dict_of_courses, initial_course_pref)
        end
        
        # 8. compile matching as a list of pairs
        matching = []
        for student in dict_of_students
            if student.second["match"] in ["", "UNMATCHED"]
                # if student is unmatched, put a none
                push!(matching, (student.first, "none"))
            else
                # otherwise student is matched
                push!(matching, (student.first, student.second["match"]))
            end
        end
        for course in dict_of_courses
            if course.second["match"] in ["", "UNMATCHED"]
                # given the above, all matched courses already exist so only add unmatched courses
                push!(matching, ("none", course.first))
            end
        end
        return matching
    end

    function julia_main()::Cint
        #if length(ARGS) >= 3 # do not run if called via a Jupyter notebook
        arguments = get_switches()
        user = "james"#arguments["username"]
        pass = "4james2use"#arguments["pass"]
        serv = "match.microeconomics.ca/api"#arguments["server"]
        verb = arguments["verbose"]
        SAVE_TO_DATABASE = true#arguments["save"]
        # 1. match PhD students only to start with
        first_matching = main(user, pass, serv, verb, true, nothing, nothing)

        # 2. take the unmatched agents, including MA, and match them
        matched_students = []
        unmatched_courses = []
        final_matching = []
        for match in first_matching
            if match[1] != "none" && match[2] != "none" # if this is an actual match, add student
                push!(matched_students, match[1])
                push!(final_matching, match)
            end
            if match[1] == "none" && match[2] != "none" # if a course has no student, it is unmatched
                push!(unmatched_courses, match[2])
            end
        end
        second_matching = main(user, pass, serv, verb, false, matched_students, unmatched_courses)
        for match in second_matching
            push!(final_matching, match)
        end
        println(final_matching)
        if SAVE_TO_DATABASE
            # initialize blank table
            println("saving to table")
            #d = DBInterface.connect(MySQL.Connection,arguments["host"], arguments["user"], arguments["password"], db =arguments["database"], port = arguments["port"])
            d = DBInterface.connect(MySQL.Connection,"127.0.0.1", "james", "1www", db ="ta_allocation", port = 3306)
            query = "drop table if exists deferred_acceptance_outcome"
            DBInterface.execute(d, query)
            query = "create table deferred_acceptance_outcome (id int auto_increment primary key, block_id int, student_block_id int )"
            DBInterface.execute(d, query)
            query = "insert into deferred_acceptance_outcome set block_id=?,student_block_id=?"
            stm = DBInterface.prepare(d, query)
            # save the allocation
            for match in final_matching
                # each match is (student, course)
                if match[1] == "none"
                    DBInterface.execute(stm, [match[2], missing])
                elseif match[2] == "none"
                    DBInterface.execute(stm, [missing, match[1]])
                else
                    DBInterface.execute(stm, [match[2], match[1]])
                end
            end
            println("done saving to table")
        end
        #else
        #    println("Warning: script is being called without running algorithm. Results will not be generated unless functions are called manually.")
        #end
        return 0
    end
end